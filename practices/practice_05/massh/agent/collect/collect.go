// Package collect reads the state of a Linux Server from /proc and friends into a Snapshot.
package collect

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"massh/agent/snapshot"
)

// Collector builds Snapshots. Rates (CPU %, network speed) are measured between consecutive
// Collect calls; Reset forgets the previous sample so an idle Agent keeps no state.
type Collector struct {
	// Root is prefixed to every path read; "/" on a real Server, a fixture tree in tests.
	Root    string
	Version string
	Now     func() time.Time
	// Statfs returns total and available bytes of the filesystem at path.
	Statfs func(path string) (total, free uint64, err error)

	SkipProcesses bool
	SkipDocker    bool

	prev *sample
}

// sample holds the cumulative counters rates are derived from.
type sample struct {
	at      time.Time
	cpu     []cpuTimes // index 0 is the aggregate line
	rx, tx  uint64
	procCPU map[int]uint64
}

func (c *Collector) Reset() { c.prev = nil }

func (c *Collector) Collect() snapshot.Snapshot {
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	cur := &sample{at: now()}
	s := snapshot.Snapshot{
		FormatVersion: snapshot.FormatVersion,
		AgentVersion:  c.Version,
		Time:          cur.at,
		Overview:      c.overview(cur),
		Docker:        snapshot.NoDocker(),
	}
	if !c.SkipProcesses {
		procs := c.processes(cur)
		s.Processes = make([]snapshot.Process, len(procs))
		for i, p := range procs {
			s.Processes[i] = p.Process
		}
		s.Ports = c.ports(procs)
	}
	c.prev = cur
	return s
}

func (c *Collector) path(p string) string { return filepath.Join(c.Root, p) }

func (c *Collector) read(p string) string {
	data, err := os.ReadFile(c.path(p))
	if err != nil {
		return ""
	}
	return string(data)
}

func (c *Collector) overview(cur *sample) snapshot.Overview {
	o := snapshot.Overview{
		OS:     osName(c.read("etc/os-release")),
		Kernel: strings.TrimSpace(c.read("proc/sys/kernel/osrelease")),
	}
	if f := strings.Fields(c.read("proc/uptime")); len(f) > 0 {
		up, _ := strconv.ParseFloat(f[0], 64)
		o.UptimeSeconds = int64(up)
	}
	if f := strings.Fields(c.read("proc/loadavg")); len(f) >= 3 {
		for i := range 3 {
			o.LoadAverage[i], _ = strconv.ParseFloat(f[i], 64)
		}
	}
	o.CPU = c.cpu(cur)
	o.Memory, o.Swap = memory(c.read("proc/meminfo"))
	o.Disks = c.disks()
	o.Network = c.network(cur)
	return o
}

func osName(release string) string {
	values := map[string]string{}
	for line := range strings.Lines(release) {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			values[k] = strings.Trim(v, `"'`)
		}
	}
	if v := values["PRETTY_NAME"]; v != "" {
		return v
	}
	return strings.TrimSpace(values["NAME"] + " " + values["VERSION_ID"])
}

type cpuTimes struct{ busy, total uint64 }

func (c *Collector) cpu(cur *sample) snapshot.CPU {
	cpu := snapshot.CPU{PerCorePercent: []float64{}}
	for line := range strings.Lines(c.read("proc/cpuinfo")) {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == "model name" && cpu.Model == "" {
			cpu.Model = strings.TrimSpace(v)
		}
	}
	for line := range strings.Lines(c.read("proc/stat")) {
		f := strings.Fields(line)
		if len(f) < 5 || !strings.HasPrefix(f[0], "cpu") {
			continue
		}
		var t cpuTimes
		for i, field := range f[1:] {
			n, _ := strconv.ParseUint(field, 10, 64)
			if i >= 8 { // guest and guest_nice are already counted in user and nice
				break
			}
			t.total += n
			if i != 3 && i != 4 { // idle, iowait
				t.busy += n
			}
		}
		cur.cpu = append(cur.cpu, t)
	}
	if n := len(cur.cpu) - 1; n > 0 {
		cpu.Cores = n
	}
	if cpu.Cores == 0 {
		cpu.Cores = strings.Count(c.read("proc/cpuinfo"), "processor\t")
	}
	if c.prev == nil || len(c.prev.cpu) != len(cur.cpu) {
		for range cpu.Cores {
			cpu.PerCorePercent = append(cpu.PerCorePercent, 0)
		}
		return cpu
	}
	for i, t := range cur.cpu {
		p := percent(t, c.prev.cpu[i])
		if i == 0 {
			cpu.UsagePercent = p
		} else {
			cpu.PerCorePercent = append(cpu.PerCorePercent, p)
		}
	}
	return cpu
}

func percent(cur, prev cpuTimes) float64 {
	if cur.total <= prev.total || cur.busy < prev.busy {
		return 0
	}
	return round2(float64(cur.busy-prev.busy) / float64(cur.total-prev.total) * 100)
}

func round2(v float64) float64 { return float64(int64(v*100+0.5)) / 100 }

func memory(meminfo string) (mem, swap snapshot.Usage) {
	kb := map[string]uint64{}
	for line := range strings.Lines(meminfo) {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		if f := strings.Fields(v); len(f) > 0 {
			n, _ := strconv.ParseUint(f[0], 10, 64)
			kb[k] = n * 1024
		}
	}
	avail, ok := kb["MemAvailable"]
	if !ok {
		avail = kb["MemFree"] + kb["Buffers"] + kb["Cached"]
	}
	mem = snapshot.Usage{TotalBytes: kb["MemTotal"], UsedBytes: sub(kb["MemTotal"], avail)}
	swap = snapshot.Usage{TotalBytes: kb["SwapTotal"], UsedBytes: sub(kb["SwapTotal"], kb["SwapFree"])}
	return
}

func sub(a, b uint64) uint64 {
	if b > a {
		return 0
	}
	return a - b
}

// disks lists block-device filesystems once per device, plus an overlay root inside containers.
func (c *Collector) disks() []snapshot.Disk {
	disks := []snapshot.Disk{}
	if c.Statfs == nil {
		return disks
	}
	seen := map[string]bool{}
	scanner := bufio.NewScanner(strings.NewReader(c.read("proc/mounts")))
	for scanner.Scan() {
		f := strings.Fields(scanner.Text())
		if len(f) < 3 {
			continue
		}
		device, mount, fstype := f[0], unescapeMount(f[1]), f[2]
		real := strings.HasPrefix(device, "/dev/") && !strings.HasPrefix(device, "/dev/loop") && fstype != "squashfs"
		if !real && !(mount == "/" && fstype == "overlay") {
			continue
		}
		if seen[device] {
			continue
		}
		total, free, err := c.Statfs(c.path(mount))
		if err != nil || total == 0 {
			continue
		}
		seen[device] = true
		disks = append(disks, snapshot.Disk{MountPoint: mount, TotalBytes: total, UsedBytes: sub(total, free)})
	}
	return disks
}

// unescapeMount decodes the octal escapes (\040 for space) used in /proc/mounts.
func unescapeMount(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// network sums traffic of physical-ish interfaces; loopback and Docker bridges/veths would double-count.
func (c *Collector) network(cur *sample) snapshot.Network {
	for line := range strings.Lines(c.read("proc/net/dev")) {
		name, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		name = strings.TrimSpace(name)
		if name == "lo" || strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "br-") {
			continue
		}
		f := strings.Fields(rest)
		if len(f) < 9 {
			continue
		}
		rx, _ := strconv.ParseUint(f[0], 10, 64)
		tx, _ := strconv.ParseUint(f[8], 10, 64)
		cur.rx += rx
		cur.tx += tx
	}
	if c.prev == nil {
		return snapshot.Network{}
	}
	secs := cur.at.Sub(c.prev.at).Seconds()
	if secs <= 0 {
		return snapshot.Network{}
	}
	return snapshot.Network{
		RxBytesPerSecond: uint64(float64(sub(cur.rx, c.prev.rx)) / secs),
		TxBytesPerSecond: uint64(float64(sub(cur.tx, c.prev.tx)) / secs),
	}
}
