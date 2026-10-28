//go:build integration

// Package integration runs the Agent inside Linux test Servers (OrbStack/Docker) and checks it from outside.
package integration

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"massh/agent/snapshot"
)

// binaries cross-compiles the Agent and the probe for the Linux test Servers.
func binaries(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil { // unprivileged users inside the Server run these too
		t.Fatal(err)
	}
	for name, pkg := range map[string]string{"massh-agent": "../cmd/massh-agent", "massh-probe": "./probe"} {
		cmd := exec.Command("go", "build", "-ldflags", "-X main.version=0.1.0", "-o", filepath.Join(dir, name), pkg)
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+runtime.GOARCH)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("build %s: %v\n%s", name, err, out)
		}
	}
	return dir
}

// testServer is a running container with systemd, sshd and optionally Docker.
type testServer struct {
	t    *testing.T
	name string
}

func startServer(t *testing.T, image, binDir string) *testServer {
	t.Helper()
	name := fmt.Sprintf("massh-it-%d", time.Now().UnixNano())
	args := []string{"run", "-d", "--rm", "--name", name, "--privileged", "--cgroupns=host",
		"-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock"}
	if binDir != "" {
		args = append(args, "-v", binDir+":/opt/massh-test:ro")
	}
	args = append(args, image)
	if out, err := exec.Command("docker", args...).CombinedOutput(); err != nil {
		t.Fatalf("docker run: %v\n%s", err, out)
	}
	s := &testServer{t: t, name: name}
	t.Cleanup(func() { exec.Command("docker", "rm", "-f", name).Run() })
	s.waitFor("systemctl is-system-running --wait >/dev/null 2>&1; systemctl is-active ssh", 60*time.Second)
	return s
}

func (s *testServer) exec(script string) (string, error) {
	out, err := exec.Command("docker", "exec", s.name, "sh", "-c", script).CombinedOutput()
	return string(out), err
}

func (s *testServer) mustExec(script string) string {
	s.t.Helper()
	out, err := s.exec(script)
	if err != nil {
		s.t.Fatalf("%s: %v\n%s", script, err, out)
	}
	return out
}

func (s *testServer) waitFor(script string, timeout time.Duration) {
	s.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		out, err := s.exec(script)
		if err == nil {
			return
		}
		if time.Now().After(deadline) {
			s.t.Fatalf("timed out waiting for %q: %v\n%s", script, err, out)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// runAgent starts the test Agent binary in the background as root.
func (s *testServer) runAgent() { s.runAgentAs("root") }

// runAgentAs starts the test Agent binary in the background as the given user, without extra capabilities.
func (s *testServer) runAgentAs(user string) {
	s.t.Helper()
	s.mustExec(fmt.Sprintf("setpriv --reuid=%[1]s --regid=$(id -g %[1]s) --init-groups -- nohup /opt/massh-test/massh-agent >/tmp/agent.log 2>&1 &", user))
	s.waitFor("ss -ltn | grep -q 127.0.0.1:12092", 10*time.Second)
}

func (s *testServer) probe(n int, addr string) []snapshot.Snapshot {
	s.t.Helper()
	out := s.mustExec(fmt.Sprintf("/opt/massh-test/massh-probe -n %d -addr %s", n, addr))
	var snaps []snapshot.Snapshot
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	for sc.Scan() {
		var snap snapshot.Snapshot
		dec := json.NewDecoder(bytes.NewReader(sc.Bytes()))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&snap); err != nil {
			s.t.Fatalf("snapshot does not match the contract: %v\n%s", err, sc.Text())
		}
		snaps = append(snaps, snap)
	}
	if len(snaps) != n {
		s.t.Fatalf("got %d snapshots, want %d\n%s", len(snaps), n, out)
	}
	return snaps
}

// cpuTicks is the user+system CPU time the Agent process has used so far.
func (s *testServer) cpuTicks() int {
	s.t.Helper()
	out := s.mustExec("cat /proc/$(pgrep -f /opt/massh-test/massh-agent | head -1)/stat")
	f := strings.Fields(out[strings.LastIndex(out, ")")+2:])
	var utime, stime int
	fmt.Sscan(f[11], &utime)
	fmt.Sscan(f[12], &stime)
	return utime + stime
}
