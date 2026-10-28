package collect_test

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"massh/agent/snapshot"
)

func TestProcessesExcludeKernelThreads(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)
	col.SkipProcesses = false

	got := col.Collect().Processes
	want := []snapshot.Process{
		{PID: 1, Name: "systemd", User: "root", MemoryBytes: 13238272, Command: "/sbin/init splash"},
		{PID: 600, Name: "systemd-resolve", User: "systemd-resolve", MemoryBytes: 8388608, Command: "/lib/systemd/systemd-resolved"},
		{PID: 812, Name: "sshd", User: "root", MemoryBytes: 9437184, Command: "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"},
		{PID: 2045, Name: "postgres", User: "postgres", MemoryBytes: 268435456, Command: "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main"},
		{PID: 3100, Name: "my (weird) app", User: "deploy", MemoryBytes: 4194304, Command: "./app --flag=a b"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("processes\n got %+v\nwant %+v", got, want)
	}
}

func TestProcessCPUIsMeasuredBetweenSnapshots(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)
	col.SkipProcesses = false
	col.Collect()

	// postgres used 100 more ticks (1 s of CPU) over 2 s of wall time.
	write(t, root, "proc/2045/stat", "2045 (postgres) S 1 2045 2045 0 -1 4194368 100 0 0 0 1100 500 0 0 20 0 1 0 100 1000000 200\n")
	c.t = c.t.Add(2 * time.Second)
	for _, p := range col.Collect().Processes {
		want := 0.0
		if p.PID == 2045 {
			want = 50
		}
		if p.CPUPercent != want {
			t.Errorf("pid %d cpu = %v, want %v", p.PID, p.CPUPercent, want)
		}
	}
}

func TestListeningPortsWithOwners(t *testing.T) {
	root := fixtureRoot(t)
	col := newCollector(root, &clock{time.Now()})
	col.SkipProcesses = false

	got := col.Collect().Ports
	want := []snapshot.Port{
		{Protocol: "tcp", Address: "0.0.0.0", Port: 22, Owner: snapshot.ProcessOwner(812, "sshd")},
		{Protocol: "udp", Address: "127.0.0.53", Port: 53, Owner: snapshot.ProcessOwner(600, "systemd-resolve")},
		{Protocol: "tcp", Address: "127.0.0.1", Port: 5432, Owner: snapshot.ProcessOwner(2045, "postgres")},
		{Protocol: "tcp", Address: "::1", Port: 5432, Owner: snapshot.ProcessOwner(2045, "postgres")},
		// No readable fd points at this socket: the port is still listed, without an owner.
		{Protocol: "tcp", Address: "0.0.0.0", Port: 8765},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ports\n got %s\nwant %s", describe(got), describe(want))
	}
}

func describe(ports []snapshot.Port) string {
	s := ""
	for _, p := range ports {
		owner := "-"
		if p.Owner != nil {
			owner = p.Owner.Kind + ":" + p.Owner.Name
		}
		s += "\n  " + p.Protocol + " " + p.Address + " " + strconv.Itoa(p.Port) + " " + owner
	}
	return s
}
