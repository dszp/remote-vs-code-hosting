// 1p-sign-filter: an SSH agent that exposes only allowlisted keys from an upstream agent.
//
// It runs ON THE MAC in front of the 1Password SSH agent (mac/1p-sign-filter-setup.sh),
// and the always-on carrier (mac/forward-agent-setup.sh) forwards THIS socket to the VM in
// place of 1Password's.
// The filter has to live on the Mac: on the VM, anything there could skip it by talking
// to the raw forwarded socket. Here, the VM can only ever reach what this process lets
// through:
//
//   - List returns only the allowed key.
//   - Sign / SignWithFlags reach 1Password only for the allowed key, only for a git
//     signature (an SSHSIG blob in the "git" namespace), and 1Password still shows its
//     own approval prompt for each one. A request to sign anything else, such as an SSH
//     login challenge, is refused, so the VM cannot use the key to log in anywhere.
//   - Add, Remove, RemoveAll, Lock, Unlock, Signers and extensions are refused.
//
// Each client connection dials the upstream socket fresh, so a 1Password restart doesn't
// leave the filter holding a dead connection. Refusals are logged to stderr with the
// operation and the requested fingerprint only — never key material.
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

var errRefused = errors.New("1p-sign-filter: operation not permitted")

// filter is an agent.ExtendedAgent that forwards only what the allowlist permits.
type filter struct {
	upstream agent.ExtendedAgent
	allow    string // SHA256:… fingerprint
	logf     func(format string, args ...any)
}

func (f *filter) allowed(key ssh.PublicKey) bool {
	return ssh.FingerprintSHA256(key) == f.allow
}

func (f *filter) refuse(op string, key ssh.PublicKey) error {
	fp := "-"
	if key != nil {
		fp = ssh.FingerprintSHA256(key)
	}
	f.logf("refused %s (key %s)", op, fp)
	return errRefused
}

func (f *filter) List() ([]*agent.Key, error) {
	keys, err := f.upstream.List()
	if err != nil {
		return nil, err
	}
	var kept []*agent.Key
	for _, k := range keys {
		if f.allowed(k) {
			kept = append(kept, k)
		}
	}
	return kept, nil
}

// gitSignature reports whether data is what `ssh-keygen -Y sign -n git` asks an
// agent to sign: the literal preamble "SSHSIG", then the namespace as an SSH string.
// An SSH login challenge starts with a length-prefixed session ID instead, so it can
// never pass.
func gitSignature(data []byte) bool {
	const magic = "SSHSIG"
	if !bytes.HasPrefix(data, []byte(magic)) || len(data) < len(magic)+4 {
		return false
	}
	rest := data[len(magic):]
	n := binary.BigEndian.Uint32(rest)
	return uint64(n) <= uint64(len(rest)-4) && string(rest[4:4+n]) == "git"
}

func (f *filter) Sign(key ssh.PublicKey, data []byte) (*ssh.Signature, error) {
	if !f.allowed(key) {
		return nil, f.refuse("sign", key)
	}
	if !gitSignature(data) {
		return nil, f.refuse("sign (not a git signature)", key)
	}
	return f.upstream.Sign(key, data)
}

func (f *filter) SignWithFlags(key ssh.PublicKey, data []byte, flags agent.SignatureFlags) (*ssh.Signature, error) {
	if !f.allowed(key) {
		return nil, f.refuse("sign", key)
	}
	if !gitSignature(data) {
		return nil, f.refuse("sign (not a git signature)", key)
	}
	return f.upstream.SignWithFlags(key, data, flags)
}

func (f *filter) Add(agent.AddedKey) error       { return f.refuse("add", nil) }
func (f *filter) Remove(key ssh.PublicKey) error { return f.refuse("remove", key) }
func (f *filter) RemoveAll() error               { return f.refuse("remove-all", nil) }
func (f *filter) Lock([]byte) error              { return f.refuse("lock", nil) }
func (f *filter) Unlock([]byte) error            { return f.refuse("unlock", nil) }
func (f *filter) Signers() ([]ssh.Signer, error) { return nil, f.refuse("signers", nil) }
func (f *filter) Extension(string, []byte) ([]byte, error) {
	return nil, agent.ErrExtensionUnsupported
}

// serveConn relays one client connection through a fresh upstream connection.
func serveConn(client net.Conn, upstreamPath, allow string, logger *log.Logger) {
	defer client.Close()
	up, err := net.Dial("unix", upstreamPath)
	if err != nil {
		logger.Printf("upstream unavailable: %v", err)
		return
	}
	defer up.Close()
	f := &filter{upstream: agent.NewClient(up), allow: allow, logf: logger.Printf}
	if err := agent.ServeAgent(f, client); err != nil && !errors.Is(err, io.EOF) {
		logger.Printf("connection ended: %v", err)
	}
}

type config struct {
	upstream, listen, allow string
}

func parseFlags(args []string) (config, error) {
	home, _ := os.UserHomeDir()
	fs := flag.NewFlagSet("1p-sign-filter", flag.ContinueOnError)
	var c config
	fs.StringVar(&c.upstream, "upstream", filepath.Join(home, ".1password", "agent.sock"), "upstream agent socket")
	fs.StringVar(&c.listen, "listen", filepath.Join(home, ".1password-filter", "sign.sock"), "socket to serve")
	fs.StringVar(&c.allow, "allow", "", "SHA256:… fingerprint of the only key to expose (required)")
	if err := fs.Parse(args); err != nil {
		return c, err
	}
	// Fail closed: without an allowlist entry there is nothing safe to serve.
	if !strings.HasPrefix(c.allow, "SHA256:") || len(c.allow) <= len("SHA256:") {
		return c, errors.New("-allow SHA256:<fingerprint> is required")
	}
	return c, nil
}

// listen creates the socket with a 0700 parent and 0600 mode, replacing a stale one.
func listen(path string) (net.Listener, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	old := syscall.Umask(0o177)
	l, err := net.Listen("unix", path)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	return l, os.Chmod(path, 0o600)
}

func run(args []string, logger *log.Logger) error {
	c, err := parseFlags(args)
	if err != nil {
		return err
	}
	l, err := listen(c.listen)
	if err != nil {
		return fmt.Errorf("listen %s: %w", c.listen, err)
	}
	defer l.Close()
	logger.Printf("listening on %s, upstream %s, allowing %s", c.listen, c.upstream, c.allow)
	for {
		conn, err := l.Accept()
		if err != nil {
			return err
		}
		go serveConn(conn, c.upstream, c.allow, logger)
	}
}

func main() {
	logger := log.New(os.Stderr, "1p-sign-filter: ", log.LstdFlags)
	if err := run(os.Args[1:], logger); err != nil {
		logger.Print(err)
		os.Exit(1)
	}
}
