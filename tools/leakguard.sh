#!/usr/bin/env bash
# leakguard — refuse a commit that stages content you never meant to publish.
#
# Two kinds of check:
#
#   1. BUILT-IN, generic. Absolute home paths, email addresses, private-key
#      headers, and the like. These need no configuration and are wrong in a
#      public repo regardless of who you are.
#
#   2. YOUR OWN names — clients, private repos, internal hostnames. These live
#      in a patterns file that is NEVER COMMITTED, because a denylist of secret
#      names committed to a public repo publishes exactly what it protects.
#      Default location `.git/leakguard-patterns` (inside .git, so it cannot be
#      pushed by accident); override with $LEAKGUARD_PATTERNS.
#      Copy .leakguard.example to get started.
#
# Install:  bash tools/install-hooks.sh
# Bypass:   git commit --no-verify     (documented on purpose — a guard nobody
#                                       can override is a guard people delete)
set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[ -t 2 ] || { RED=""; YEL=""; OFF=""; }

PATTERNS="${LEAKGUARD_PATTERNS:-$(git rev-parse --git-dir)/leakguard-patterns}"

# Staged, non-deleted paths. -z + read -d handles spaces and newlines in names.
mapfile -d '' -t FILES < <(git diff --cached --name-only --diff-filter=ACMR -z)
[ ${#FILES[@]} -gt 0 ] || exit 0

hits=0

report() {  # file, line, label, text
  printf '%s  %s:%s%s  %s%s%s\n' "$RED" "$1" "$2" "$OFF" "$YEL" "$3" "$OFF" >&2
  printf '      %s\n' "$4" >&2
  hits=$((hits + 1))
}

# Scan the STAGED blob, not the worktree file: those differ whenever something
# is staged and then edited, and the blob is what would actually be published.
staged_content() { git show ":$1" 2>/dev/null; }

is_text() { git show ":$1" 2>/dev/null | head -c 8000 | grep -qIm1 '' ; }

scan_builtin() {
  local f="$1" line no
  while IFS= read -r line; do
    no="${line%%:*}"; line="${line#*:}"
    case "$line" in
      *'-----BEGIN '*'PRIVATE KEY-----'*) report "$f" "$no" "private key material" "$line" ;;
    esac
  done < <(staged_content "$f" | grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' || true)

  while IFS= read -r line; do
    no="${line%%:*}"
    report "$f" "$no" "absolute home path" "${line#*:}"
    # Placeholder users are the whole point of a deploy guide, and a guard that
    # flags /home/user/ on every commit is a guard that gets uninstalled. Skip
    # the conventional stand-ins and dot-entries (/home/.vscode-server is not a
    # username at all); flag anything that looks like a real account.
  done < <(staged_content "$f" | grep -nE '/(home|Users)/[a-zA-Z0-9_.$<>{}-]+/' \
      | grep -vE '/(home|Users)/(x|y|user|users|dev|you|me|alex|jane|john|USER|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}|<[^>]+>|__[A-Z_]+__|\.[a-zA-Z0-9_.-]+)/' || true)

  while IFS= read -r line; do
    no="${line%%:*}"
    report "$f" "$no" "email address" "${line#*:}"
  done < <(staged_content "$f" \
      | grep -nE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
      | grep -vE 'users\.noreply\.github\.com|@example\.(com|org)|@[A-Za-z0-9.-]*\.invalid' || true)
}

scan_patterns() {
  local f="$1" pat label line no
  [ -r "$PATTERNS" ] || return 0
  while IFS= read -r pat; do
    pat="${pat%%#*}"; pat="$(printf '%s' "$pat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$pat" ] || continue
    while IFS= read -r line; do
      no="${line%%:*}"
      report "$f" "$no" "denylisted term" "${line#*:}"
    done < <(staged_content "$f" | grep -niF -- "$pat" || true)
  done < "$PATTERNS"
}

for f in "${FILES[@]}"; do
  is_text "$f" || continue
  case "$f" in .leakguard.example|tools/leakguard.sh) continue ;; esac
  scan_builtin "$f"
  scan_patterns "$f"
done

if [ "$hits" -gt 0 ]; then
  printf '\n%sleakguard: %d finding(s) in staged content — commit refused.%s\n' "$RED" "$hits" "$OFF" >&2
  printf 'Fix them, or bypass deliberately with: git commit --no-verify\n' >&2
  [ -r "$PATTERNS" ] || printf 'No patterns file at %s (built-in checks only).\n' "$PATTERNS" >&2
  exit 1
fi
exit 0
