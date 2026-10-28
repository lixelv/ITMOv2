//go:build integration

package integration

import (
	"strings"
	"testing"
	"time"
)

func TestOverviewStream(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.runAgent()

	start := time.Now()
	snaps := srv.probe(3, "127.0.0.1:12092")
	if elapsed := time.Since(start); elapsed > 5*time.Second || elapsed < 1500*time.Millisecond {
		t.Errorf("3 snapshots took %v, want about one per second", elapsed)
	}
	for i := 1; i < len(snaps); i++ {
		gap := snaps[i].Time.Sub(snaps[i-1].Time)
		if gap < 800*time.Millisecond || gap > 1300*time.Millisecond {
			t.Errorf("gap between snapshots %v, want ~1s", gap)
		}
	}
	s := snaps[len(snaps)-1]
	o := s.Overview
	if s.AgentVersion != "0.1.0" || !strings.Contains(o.OS, "Ubuntu") || o.Kernel == "" || o.UptimeSeconds <= 0 {
		t.Errorf("system info: %+v", o)
	}
	if o.CPU.Cores == 0 || len(o.CPU.PerCorePercent) != o.CPU.Cores {
		t.Errorf("cpu: %+v", o.CPU)
	}
	if o.Memory.TotalBytes == 0 || o.Memory.UsedBytes == 0 || o.Memory.UsedBytes > o.Memory.TotalBytes {
		t.Errorf("memory: %+v", o.Memory)
	}
	if len(o.Disks) == 0 || o.Disks[0].MountPoint != "/" || o.Disks[0].TotalBytes == 0 {
		t.Errorf("disks: %+v", o.Disks)
	}
	if s.Docker.Available {
		t.Error("Docker reported on a Server without it")
	}
}

func TestAgentListensOnlyOnLoopback(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.runAgent()
	ip := strings.TrimSpace(srv.mustExec("hostname -I | awk '{print $1}'"))
	if out, err := srv.exec("/opt/massh-test/massh-probe -n 1 -addr " + ip + ":12092"); err == nil {
		t.Fatalf("Agent answered on external interface %s:\n%s", ip, out)
	}
	if listeners := srv.mustExec("ss -ltnH 'sport = :12092'"); strings.Count(strings.TrimSpace(listeners), "\n") != 0 ||
		!strings.Contains(listeners, "127.0.0.1:12092") {
		t.Fatalf("unexpected listeners:\n%s", listeners)
	}
}

func TestIdleAgentUsesNoCPU(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.runAgent()

	srv.probe(2, "127.0.0.1:12092") // one session, then idle again
	time.Sleep(time.Second)
	before := srv.cpuTicks()
	time.Sleep(5 * time.Second)
	if used := srv.cpuTicks() - before; used > 1 {
		t.Fatalf("idle Agent used %d CPU ticks in 5s", used)
	}
}

func TestSeveralClientsAtOnce(t *testing.T) {
	srv := startServer(t, "massh-test-server:nodocker", binaries(t))
	srv.runAgent()
	out := srv.mustExec(`for i in 1 2 3; do /opt/massh-test/massh-probe -n 2 > /tmp/p$i & done; wait; cat /tmp/p1 /tmp/p2 /tmp/p3 | wc -l`)
	if strings.TrimSpace(out) != "6" {
		t.Fatalf("three concurrent clients got %s snapshots, want 6", out)
	}
}
