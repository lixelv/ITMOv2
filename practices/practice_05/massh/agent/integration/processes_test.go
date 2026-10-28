//go:build integration

package integration

import (
	"strings"
	"testing"

	"massh/agent/snapshot"
)

func findPort(snap snapshot.Snapshot, proto string, port int) *snapshot.Port {
	for i := range snap.Ports {
		if snap.Ports[i].Protocol == proto && snap.Ports[i].Port == port {
			return &snap.Ports[i]
		}
	}
	return nil
}

func TestProcessesAndPortsWithOwners(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.waitFor("ss -ltn | grep -q :8765", 30e9)
	srv.runAgent()
	snap := srv.probe(2, "127.0.0.1:12092")[1]

	var init, http *snapshot.Process
	for i, p := range snap.Processes {
		switch {
		case p.PID == 1:
			init = &snap.Processes[i]
		case strings.Contains(p.Command, "http.server 8765"):
			http = &snap.Processes[i]
		}
	}
	if init == nil || init.Name != "systemd" || init.User != "root" {
		t.Errorf("system process missing: %+v", init)
	}
	if http == nil || http.Name != "python3" || http.MemoryBytes == 0 {
		t.Fatalf("test service missing: %+v", http)
	}

	port := findPort(snap, "tcp", 8765)
	if port == nil || port.Address != "0.0.0.0" {
		t.Fatalf("port 8765 missing: %+v", snap.Ports)
	}
	if port.Owner == nil || port.Owner.Kind != "process" || port.Owner.PID != http.PID || port.Owner.Name != "python3" {
		t.Errorf("port 8765 owner = %+v, want python3 pid %d", port.Owner, http.PID)
	}
	// Ubuntu 24.04 socket-activates sshd, so port 22 may belong to systemd.
	if ssh := findPort(snap, "tcp", 22); ssh == nil || ssh.Owner == nil {
		t.Errorf("sshd port: %+v", ssh)
	}
}

func TestPortsWithoutPermissionHaveNoOwner(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.waitFor("ss -ltn | grep -q :8765", 30e9)
	srv.runAgentAs("nobody")
	snap := srv.probe(1, "127.0.0.1:12092")[0]

	port := findPort(snap, "tcp", 8765)
	if port == nil {
		t.Fatalf("port 8765 must be listed even without permission: %+v", snap.Ports)
	}
	if port.Owner != nil {
		t.Errorf("unprivileged Agent cannot know the owner, got %+v", port.Owner)
	}
	if len(snap.Processes) == 0 {
		t.Error("processes are readable without privileges")
	}
}
