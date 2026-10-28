package collect_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"massh/agent/collect"
	"massh/agent/snapshot"
)

// fixtureRoot copies testdata/root into a temp dir so tests can advance counters between snapshots.
func fixtureRoot(t *testing.T) string {
	t.Helper()
	dst := t.TempDir()
	if out, err := exec.Command("cp", "-R", "testdata/root/.", dst).CombinedOutput(); err != nil {
		t.Fatalf("copy fixtures: %v\n%s", err, out)
	}
	return dst
}

func write(t *testing.T, root, name, content string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newCollector(root string, c *clock) *collect.Collector {
	return &collect.Collector{
		Root:    root,
		Version: "0.1.0",
		Now:     c.now,
		Statfs: func(path string) (total, free uint64, err error) {
			switch path {
			case filepath.Join(root, "/"):
				return 40 << 30, 28 << 30, nil
			case filepath.Join(root, "/boot/efi"):
				return 512 << 20, 500 << 20, nil
			}
			return 0, 0, os.ErrNotExist
		},
		SkipProcesses: true,
		SkipDocker:    true,
	}
}

func TestOverviewFromProc(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	s := newCollector(root, c).Collect()

	if s.FormatVersion != snapshot.FormatVersion || s.AgentVersion != "0.1.0" || !s.Time.Equal(c.t) {
		t.Errorf("header = %d %q %v", s.FormatVersion, s.AgentVersion, s.Time)
	}
	o := s.Overview
	if o.OS != "Ubuntu 24.04.1 LTS" || o.Kernel != "6.8.0-45-generic" || o.UptimeSeconds != 864210 {
		t.Errorf("system = %q %q %d", o.OS, o.Kernel, o.UptimeSeconds)
	}
	if o.LoadAverage != [3]float64{0.42, 0.35, 0.30} {
		t.Errorf("load = %v", o.LoadAverage)
	}
	if o.CPU.Model != "AMD EPYC 7763 64-Core Processor" || o.CPU.Cores != 2 {
		t.Errorf("cpu = %+v", o.CPU)
	}
	if o.Memory != (snapshot.Usage{TotalBytes: 4110417920, UsedBytes: 1824522240}) {
		t.Errorf("memory = %+v", o.Memory)
	}
	if o.Swap != (snapshot.Usage{TotalBytes: 2147479552, UsedBytes: 1073739776}) {
		t.Errorf("swap = %+v", o.Swap)
	}
	wantDisks := []snapshot.Disk{
		{MountPoint: "/", TotalBytes: 40 << 30, UsedBytes: 12 << 30},
		{MountPoint: "/boot/efi", TotalBytes: 512 << 20, UsedBytes: 12 << 20},
	}
	if len(o.Disks) != len(wantDisks) {
		t.Fatalf("disks = %+v", o.Disks)
	}
	for i := range wantDisks {
		if o.Disks[i] != wantDisks[i] {
			t.Errorf("disk %d = %+v, want %+v", i, o.Disks[i], wantDisks[i])
		}
	}
}

func TestRatesAreMeasuredBetweenSnapshots(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	col := newCollector(root, c)

	first := col.Collect()
	if first.Overview.CPU.UsagePercent != 0 || first.Overview.Network != (snapshot.Network{}) {
		t.Errorf("first snapshot has no previous sample, want zero rates: %+v %+v", first.Overview.CPU, first.Overview.Network)
	}

	write(t, root, "proc/stat", `cpu  1100 0 550 8200 150 0 0 0 0 0
cpu0 660 0 330 4000 60 0 0 0 0 0
cpu1 440 0 220 4200 90 0 0 0 0 0
`)
	write(t, root, "proc/net/dev", `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 199999999    1000    0    0    0     0          0         0 199999999    1000    0    0    0     0       0          0
  eth0: 1300000    5000    0    0    0     0          0         0   540000    4000    0    0    0     0       0          0
  ens5: 2100000    5000    0    0    0     0          0         0   140000    4000    0    0    0     0       0          0
docker0: 9777777    5000    0    0    0     0          0         0  9777777    4000    0    0    0     0       0          0
vethab12: 9555555    5000    0    0    0     0          0         0  9555555    4000    0    0    0     0       0          0
`)
	c.t = c.t.Add(2 * time.Second)
	second := col.Collect()

	cpu := second.Overview.CPU
	if cpu.UsagePercent != 37.5 {
		t.Errorf("cpu usage = %v, want 37.5", cpu.UsagePercent)
	}
	if len(cpu.PerCorePercent) != 2 || cpu.PerCorePercent[0] != 45 || cpu.PerCorePercent[1] != 30 {
		t.Errorf("per core = %v, want [45 30]", cpu.PerCorePercent)
	}
	if second.Overview.Network != (snapshot.Network{RxBytesPerSecond: 200000, TxBytesPerSecond: 40000}) {
		t.Errorf("network = %+v, want rx 200000 tx 40000 (lo, docker0, veth excluded)", second.Overview.Network)
	}

	col.Reset()
	third := col.Collect()
	if third.Overview.CPU.UsagePercent != 0 {
		t.Errorf("after Reset there is no previous sample, cpu = %v", third.Overview.CPU.UsagePercent)
	}
}

func TestMissingFilesDoNotPanic(t *testing.T) {
	s := (&collect.Collector{Root: t.TempDir(), SkipDocker: true}).Collect()
	if _, err := s.Encode(); err != nil {
		t.Fatal(err)
	}
}
