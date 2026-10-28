//go:build integration

package integration

import (
	"os/exec"
	"strings"
	"testing"
	"time"
)

// loadImage copies an image from the host's Docker into the test Server's Docker.
func (s *testServer) loadImage(image string) {
	s.t.Helper()
	save := exec.Command("docker", "save", image)
	load := exec.Command("docker", "exec", "-i", s.name, "docker", "load")
	pipe, err := save.StdoutPipe()
	if err != nil {
		s.t.Fatal(err)
	}
	load.Stdin = pipe
	if err := save.Start(); err != nil {
		s.t.Fatal(err)
	}
	if out, err := load.CombinedOutput(); err != nil {
		s.t.Fatalf("docker load: %v\n%s", err, out)
	}
	save.Wait()
}

func TestContainersInSnapshot(t *testing.T) {
	if err := exec.Command("docker", "image", "inspect", "busybox:1.36").Run(); err != nil {
		if out, err := exec.Command("docker", "pull", "busybox:1.36").CombinedOutput(); err != nil {
			t.Fatalf("pull busybox: %v\n%s", err, out)
		}
	}
	srv := startServer(t, "massh-test-server:docker", binaries(t))
	srv.waitFor("docker info >/dev/null 2>&1", 60*time.Second)
	srv.loadImage("busybox:1.36")
	srv.mustExec("docker run -d --name web -m 64m -p 8080:80 busybox:1.36 httpd -f -p 80")
	srv.runAgent()

	snap := srv.probe(3, "127.0.0.1:12092")[2]
	if !snap.Docker.Available || len(snap.Docker.Containers) != 1 {
		t.Fatalf("docker = %+v", snap.Docker)
	}
	c := snap.Docker.Containers[0]
	if c.Name != "web" || c.Image != "busybox:1.36" || !strings.HasPrefix(c.Status, "Up") {
		t.Errorf("container = %+v", c)
	}
	if c.MemoryBytes == 0 || c.MemoryLimitBytes != 64<<20 {
		t.Errorf("memory = %d / %d, want limit 64 MiB", c.MemoryBytes, c.MemoryLimitBytes)
	}
	if len(c.Ports) == 0 || !strings.Contains(strings.Join(c.Ports, ","), "8080->80/tcp") {
		t.Errorf("ports = %v", c.Ports)
	}
	port := findPort(snap, "tcp", 8080)
	if port == nil || port.Owner == nil || port.Owner.Kind != "container" || port.Owner.Name != "web" {
		t.Errorf("port 8080 = %+v, want owned by container web, not docker-proxy", port)
	}
}

func TestNoDockerOnServer(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.runAgent()
	snaps := srv.probe(2, "127.0.0.1:12092")
	if snaps[1].Docker.Available {
		t.Fatal("Docker reported on a Server without it")
	}
	if len(snaps[1].Processes) == 0 {
		t.Fatal("the rest of the Snapshot must still work")
	}
	if _, err := srv.exec("pgrep -f /opt/massh-test/massh-agent"); err != nil {
		t.Fatal("Agent died without Docker")
	}
}
