package docker_test

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"massh/agent/docker"
)

// fakeEngine serves a minimal Docker Engine API on a unix socket.
func fakeEngine(t *testing.T, handler http.Handler) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "dk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: handler}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return sock
}

func TestContainersWithStats(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[{"Id":"4f2a9c1b7e3d0000000000","Names":["/web"],"Image":"nginx:1.27","Status":"Up 3 hours",
		  "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"PrivatePort":443,"Type":"tcp"}]}]`))
	})
	mux.HandleFunc("GET /containers/4f2a9c1b7e3d0000000000/stats", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("stream") != "false" {
			t.Errorf("stats must not stream: %s", r.URL)
		}
		w.Write([]byte(`{"cpu_stats":{"cpu_usage":{"total_usage":5000000},"system_cpu_usage":900000000,"online_cpus":2},
		  "memory_stats":{"usage":62914560,"limit":536870912,"stats":{"inactive_file":10485760}}}`))
	})
	client := docker.New(fakeEngine(t, mux))

	got, err := client.Containers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("containers = %+v", got)
	}
	c := got[0]
	if c.ID != "4f2a9c1b7e3d" || c.Name != "web" || c.Image != "nginx:1.27" || c.Status != "Up 3 hours" {
		t.Errorf("container = %+v", c)
	}
	if c.MemoryBytes != 52428800 || c.MemoryLimitBytes != 536870912 {
		t.Errorf("memory = %d / %d, want usage minus inactive file cache", c.MemoryBytes, c.MemoryLimitBytes)
	}
	if c.CPUUsage != 5000000 || c.SystemCPUUsage != 900000000 || c.OnlineCPUs != 2 {
		t.Errorf("cpu counters = %+v", c)
	}
	want := []docker.PublishedPort{{IP: "0.0.0.0", PublicPort: 8080, PrivatePort: 80, Protocol: "tcp"}, {IP: "::", PublicPort: 8080, PrivatePort: 80, Protocol: "tcp"}, {PrivatePort: 443, Protocol: "tcp"}}
	if len(c.Ports) != len(want) {
		t.Fatalf("ports = %+v", c.Ports)
	}
	for i := range want {
		if c.Ports[i] != want[i] {
			t.Errorf("port %d = %+v, want %+v", i, c.Ports[i], want[i])
		}
	}
}

func TestMissingSocketIsAnError(t *testing.T) {
	if _, err := docker.New("/nonexistent/docker.sock").Containers(context.Background()); err == nil {
		t.Fatal("expected an error without Docker")
	}
}
