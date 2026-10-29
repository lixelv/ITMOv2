package collect_test

import (
	"os"
	"path/filepath"
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

// Per Process and second only /proc/<pid>/stat is read: memory comes from its RSS field, while the user and
// command line are read once per Process and kept until the PID is reused (a new start time).
func TestProcessMemoryIsLiveAndStaticFieldsFollowPIDReuse(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)
	col.SkipProcesses = false
	col.Collect()

	app := func() snapshot.Process {
		for _, p := range col.Collect().Processes {
			if p.PID == 3100 {
				return p
			}
		}
		t.Fatal("PID 3100 missing")
		return snapshot.Process{}
	}

	// RSS doubled: 1024 -> 2048 pages of 4 KiB.
	write(t, root, "proc/3100/stat", "3100 (my (weird) app) R 1 3100 3100 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 100 1000000 2048\n")
	c.t = c.t.Add(time.Second)
	if got := app().MemoryBytes; got != 8<<20 {
		t.Errorf("memory = %d, want %d from stat RSS", got, 8<<20)
	}

	// PID 3100 reused by another program: new start time, new command and user.
	write(t, root, "proc/3100/stat", "3100 (worker) S 1 3100 3100 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 900 1000000 10\n")
	write(t, root, "proc/3100/cmdline", "worker\x00--queue\x00jobs\x00")
	write(t, root, "proc/3100/status", "Name:\tworker\nUid:\t0\t0\t0\t0\nVmRSS:\t40 kB\n")
	c.t = c.t.Add(time.Second)
	if p := app(); p.Name != "worker" || p.Command != "worker --queue jobs" || p.User != "root" {
		t.Errorf("after PID reuse got %+v, want worker run by root", p)
	}
}

// ownerOf returns the owner name of the port, "-" when it has none, "" when the port is not listed.
func ownerOf(ports []snapshot.Port, port int) string {
	for _, p := range ports {
		if p.Port == port {
			if p.Owner == nil {
				return "-"
			}
			return p.Owner.Name
		}
	}
	return ""
}

// Owners come from reading every Process's /proc/<pid>/fd, by far the costliest part of a Snapshot; between scans
// they are remembered, so a Server with thousands of descriptors is not walked every second.
func TestPortOwnersAreRememberedBetweenSnapshots(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)
	col.SkipProcesses = false
	col.Collect()

	if err := os.RemoveAll(filepath.Join(root, "proc/812/fd")); err != nil {
		t.Fatal(err)
	}
	c.t = c.t.Add(time.Second)
	if got := ownerOf(col.Collect().Ports, 22); got != "sshd" {
		t.Errorf("owner of :22 a second later = %q, want sshd from the last scan", got)
	}

	// Scans are refreshed every half minute, so owners of closed sockets do not linger.
	c.t = c.t.Add(30 * time.Second)
	if got := ownerOf(col.Collect().Ports, 22); got != "-" {
		t.Errorf("owner of :22 after the refresh = %q, want none", got)
	}
}

func TestNewListeningPortGetsItsOwnerOnTheNextSnapshot(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)
	col.SkipProcesses = false
	col.Collect()

	tcp, err := os.ReadFile(filepath.Join(root, "proc/net/tcp"))
	if err != nil {
		t.Fatal(err)
	}
	write(t, root, "proc/net/tcp", string(tcp)+"   4: 00000000:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 40001 1 0000000000000000 100 0 0 10 0\n")
	if err := os.Symlink("socket:[40001]", filepath.Join(root, "proc/3100/fd/9")); err != nil {
		t.Fatal(err)
	}
	c.t = c.t.Add(time.Second)
	if got := ownerOf(col.Collect().Ports, 9000); got != "my (weird) app" {
		t.Errorf("owner of new :9000 = %q, want my (weird) app", got)
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
