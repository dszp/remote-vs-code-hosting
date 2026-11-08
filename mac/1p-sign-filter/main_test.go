package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

// newKey adds a fresh ed25519 key to the keyring and returns its public half.
func newKey(t *testing.T, ring agent.Agent) ssh.PublicKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := ring.Add(agent.AddedKey{PrivateKey: priv}); err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return signer.PublicKey()
}

// setup serves a filter over net.Pipe in front of a keyring holding two keys and
// returns a client for it plus the allowed and the other key.
func setup(t *testing.T) (agent.ExtendedAgent, ssh.PublicKey, ssh.PublicKey) {
	t.Helper()
	ring := agent.NewKeyring()
	allowed, other := newKey(t, ring), newKey(t, ring)
	f := &filter{
		upstream: ring.(agent.ExtendedAgent),
		allow:    ssh.FingerprintSHA256(allowed),
		logf:     log.New(io.Discard, "", 0).Printf,
	}
	srv, cli := net.Pipe()
	go agent.ServeAgent(f, srv)
	t.Cleanup(func() { cli.Close(); srv.Close() })
	return agent.NewClient(cli), allowed, other
}

func TestListShowsOnlyAllowedKey(t *testing.T) {
	c, allowed, _ := setup(t)
	keys, err := c.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || ssh.FingerprintSHA256(keys[0]) != ssh.FingerprintSHA256(allowed) {
		t.Fatalf("List = %d keys, want only the allowed one", len(keys))
	}
}

func TestSignWithAllowedKeyVerifies(t *testing.T) {
	c, allowed, _ := setup(t)
	data := []byte("tag object")
	sig, err := c.Sign(allowed, data)
	if err != nil {
		t.Fatal(err)
	}
	if err := allowed.Verify(data, sig); err != nil {
		t.Fatalf("signature does not verify: %v", err)
	}
	if _, err := c.SignWithFlags(allowed, data, 0); err != nil {
		t.Fatalf("SignWithFlags with allowed key: %v", err)
	}
}

func TestSignWithOtherKeyFails(t *testing.T) {
	c, _, other := setup(t)
	if _, err := c.Sign(other, []byte("x")); err == nil {
		t.Fatal("Sign with a non-allowed key succeeded")
	}
	if _, err := c.SignWithFlags(other, []byte("x"), 0); err == nil {
		t.Fatal("SignWithFlags with a non-allowed key succeeded")
	}
}

func TestMutationsFail(t *testing.T) {
	c, allowed, _ := setup(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	if err := c.Add(agent.AddedKey{PrivateKey: priv}); err == nil {
		t.Error("Add succeeded")
	}
	if err := c.Remove(allowed); err == nil {
		t.Error("Remove succeeded")
	}
	if err := c.RemoveAll(); err == nil {
		t.Error("RemoveAll succeeded")
	}
	if err := c.Lock([]byte("p")); err == nil {
		t.Error("Lock succeeded")
	}
	if err := c.Unlock([]byte("p")); err == nil {
		t.Error("Unlock succeeded")
	}
	if _, err := c.Extension("query", nil); err == nil {
		t.Error("Extension succeeded")
	}
	// The upstream keyring still has both keys: nothing reached it.
	if keys, _ := c.List(); len(keys) != 1 {
		t.Errorf("after refused mutations List = %d keys, want 1", len(keys))
	}
}

func TestStartupRequiresAllow(t *testing.T) {
	for _, args := range [][]string{{}, {"-allow", ""}, {"-allow", "SHA256:"}, {"-allow", "MD5:aa"}} {
		if _, err := parseFlags(args); err == nil {
			t.Errorf("parseFlags(%q) succeeded, want an error", args)
		}
	}
	if _, err := parseFlags([]string{"-allow", "SHA256:abc"}); err != nil {
		t.Errorf("parseFlags with -allow: %v", err)
	}
}

func TestListenSocketPermissions(t *testing.T) {
	// Not t.TempDir(): on macOS it lives under /var/folders/… and pushes the socket path past
	// the 104-byte sun_path limit ("bind: invalid argument").
	base, err := os.MkdirTemp("/tmp", "1psf")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(base) })
	path := filepath.Join(base, "sub", "sign.sock")
	l, err := listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if fi := mustStat(t, path); fi.Mode().Perm() != 0o600 {
		t.Errorf("socket mode = %v, want 0600", fi.Mode().Perm())
	}
	if fi := mustStat(t, filepath.Dir(path)); fi.Mode().Perm() != 0o700 {
		t.Errorf("dir mode = %v, want 0700", fi.Mode().Perm())
	}
	// A stale socket is replaced on restart.
	l.Close()
	l2, err := listen(path)
	if err != nil {
		t.Fatalf("relisten over stale socket: %v", err)
	}
	l2.Close()
}

func mustStat(t *testing.T, p string) os.FileInfo {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi
}
