#!/usr/bin/env bash
# Mac side of deploy/98-samba-share.sh: keep the VM's SMB share mounted at /Volumes/<share>
# with a LaunchAgent, so Finder / Office / Preview open VM files in place.
# Run ON YOUR MAC.
#
#   ./mac/smb-mount-setup.sh                 # mounts smb://<vm>/share
#   SMB_SHARE=Remote-VS-Code ./mac/smb-mount-setup.sh   # another share (one agent per share)
# Override via env: SSH_HOST (host alias whose HostName is the VM's Tailscale IP), DEV_USER,
# SMB_SHARE, SMB_HOST (skip the ssh lookup).
#
# Why not Finder's Cmd-K + "Login Items": on this Mac, Finder's mount helper (NetAuthSysAgent)
# hangs on "Connecting..." at its credentials stage, waiting on sharingd for an Apple ID that
# never answers, so it never prompts. mount_smbfs authenticates fine but can't read the
# Keychain (-N fails with "Authentication error"). So a small Swift helper reads the password
# from the Keychain itself and calls NetFSMountURLSync with UI disabled.
#
# Password: one Keychain internet-password item, the same kind Finder uses. Create it once
# (-w last makes security PROMPT, so the password never lands on a command line):
#   security add-internet-password -a <user> -s <vm-ip> -r 'smb ' -l '<vm> SMB' -w
# The first mount asks "smb-mount wants to use ... keychain": choose Always Allow. Rebuilding
# the helper changes its code hash, so expect that prompt once more after a re-run.
#
# The agent runs at login and every 2 min; it exits at once when the share is already
# mounted, and quietly retries while Tailscale is down. Log: ~/Library/Logs/smb-mount.log
set -euo pipefail

SSH_HOST="${SSH_HOST:-__VM_SSH_ALIAS__}"
DEV_USER="${DEV_USER:-__DEV_USER__}"
SMB_SHARE="${SMB_SHARE:-share}"
SMB_HOST="${SMB_HOST:-$(ssh -G "$SSH_HOST" | awk '$1=="hostname"{print $2}')}"
[ -n "$SMB_HOST" ] || { echo "can't resolve the VM host from ssh alias $SSH_HOST; set SMB_HOST" >&2; exit 1; }

command -v swiftc >/dev/null || { echo "swiftc not found: xcode-select --install" >&2; exit 1; }

SRC_DIR="$HOME/.local/share/smb-mount"
BIN="$HOME/.local/bin/smb-mount"
LABEL="com.__MAC_USER__.smb-mount.$SMB_SHARE"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/smb-mount.log"
mkdir -p "$SRC_DIR" "$(dirname "$BIN")" "$(dirname "$PLIST")"

if ! security find-internet-password -a "$DEV_USER" -s "$SMB_HOST" -r 'smb ' >/dev/null 2>&1; then
  echo ">> no Keychain item for $DEV_USER@$SMB_HOST; enter the SMB password (stored, not echoed)"
  security add-internet-password -a "$DEV_USER" -s "$SMB_HOST" -r 'smb ' -l "$SSH_HOST SMB" -w
fi

echo ">> building $BIN"
cat > "$SRC_DIR/smb-mount.swift" <<'SWIFT'
// smb-mount <host> <share> <user>: mount smb://user@host/share at /Volumes/<share> using the
// Keychain internet password for user@host. Exit 0 if mounted (or already mounted).
import Foundation
import NetFS
import Security

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write("usage: smb-mount <host> <share> <user>\n".data(using: .utf8)!)
  exit(2)
}
let (host, share, user) = (args[1], args[2], args[3])
func log(_ s: String) { print("\(Date()) \(user)@\(host)/\(share): \(s)") }

// Already mounted? `mount` lists it as //user@host/share on /Volumes/...
let mount = Process()
let pipe = Pipe()
mount.executableURL = URL(fileURLWithPath: "/sbin/mount")
mount.standardOutput = pipe
try mount.run()
let mounted = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
mount.waitUntilExit()
if mounted.split(separator: "\n").contains(where: { $0.contains("@\(host)/\(share) on ") }) { exit(0) }

let query: [String: Any] = [
  kSecClass as String: kSecClassInternetPassword,
  kSecAttrServer as String: host,
  kSecAttrAccount as String: user,
  kSecAttrProtocol as String: kSecAttrProtocolSMB,
  kSecReturnData as String: true,
  kSecMatchLimit as String: kSecMatchLimitOne,
]
var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
guard status == errSecSuccess, let data = item as? Data,
      let password = String(data: data, encoding: .utf8) else {
  log("no Keychain password (OSStatus \(status))")
  exit(1)
}

var comps = URLComponents()
comps.scheme = "smb"
comps.host = host
comps.path = "/" + share
// NetFS's kNAUIOptionKey / kNAUIOptionNoUI are CFSTR macros, which Swift doesn't import.
let openOptions = NSMutableDictionary(dictionary: ["UIOption": "NoUI"])
var mountpoints: Unmanaged<CFArray>?
let rc = NetFSMountURLSync(comps.url! as CFURL, nil, user as CFString, password as CFString,
                           openOptions, nil, &mountpoints)
if rc == 0 {
  let points = (mountpoints?.takeRetainedValue() as? [String]) ?? []
  log("mounted at \(points.joined(separator: ", "))")
  exit(0)
}
log("mount failed: \(rc) (\(String(cString: strerror(rc))))")
exit(1)
SWIFT
swiftc -O -o "$BIN" "$SRC_DIR/smb-mount.swift"

echo ">> writing $PLIST"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>$SMB_HOST</string>
    <string>$SMB_SHARE</string>
    <string>$DEV_USER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>120</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo ">> loaded $LABEL; first run may ask for Keychain access (Always Allow)"
sleep 3
tail -n 3 "$LOG" 2>/dev/null || true
