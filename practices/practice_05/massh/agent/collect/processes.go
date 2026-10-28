package collect

import (
	"cmp"
	"encoding/hex"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"

	"massh/agent/snapshot"
)

const (
	pfKthread = 0x00200000 // PF_KTHREAD in /proc/<pid>/stat flags
	clockTick = 100        // USER_HZ on every Linux the Agent supports
)

type procInfo struct {
	snapshot.Process
	ticks   uint64
	sockets []string // socket inodes from /proc/<pid>/fd
}

// processes lists every non-kernel-thread Process. Socket inodes are collected on the way for port owners.
func (c *Collector) processes(cur *sample) []procInfo {
	entries, err := os.ReadDir(c.path("proc"))
	if err != nil {
		return nil
	}
	users := c.users()
	cur.procCPU = map[int]uint64{}
	var elapsed float64
	if c.prev != nil {
		elapsed = cur.at.Sub(c.prev.at).Seconds()
	}
	var list []procInfo
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		p, ok := c.process(pid, users)
		if !ok {
			continue
		}
		cur.procCPU[pid] = p.ticks
		if c.prev != nil && elapsed > 0 {
			if before, ok := c.prev.procCPU[pid]; ok && p.ticks >= before {
				p.CPUPercent = round2(float64(p.ticks-before) / clockTick / elapsed * 100)
			}
		}
		list = append(list, p)
	}
	slices.SortFunc(list, func(a, b procInfo) int { return cmp.Compare(a.PID, b.PID) })
	return list
}

func (c *Collector) process(pid int, users map[string]string) (procInfo, bool) {
	dir := "proc/" + strconv.Itoa(pid)
	stat := c.read(dir + "/stat")
	open, close := strings.IndexByte(stat, '('), strings.LastIndexByte(stat, ')')
	if open < 0 || close < open {
		return procInfo{}, false
	}
	f := strings.Fields(stat[close+1:])
	if len(f) < 13 {
		return procInfo{}, false
	}
	flags, _ := strconv.ParseUint(f[6], 10, 64)
	if flags&pfKthread != 0 {
		return procInfo{}, false
	}
	utime, _ := strconv.ParseUint(f[11], 10, 64)
	stime, _ := strconv.ParseUint(f[12], 10, 64)

	p := procInfo{ticks: utime + stime}
	p.PID = pid
	p.Name = stat[open+1 : close]
	for line := range strings.Lines(c.read(dir + "/status")) {
		k, v, _ := strings.Cut(line, ":")
		switch k {
		case "Uid":
			if uid := strings.Fields(v); len(uid) > 0 {
				p.User = cmp.Or(users[uid[0]], uid[0])
			}
		case "VmRSS":
			if kb := strings.Fields(v); len(kb) > 0 {
				n, _ := strconv.ParseUint(kb[0], 10, 64)
				p.MemoryBytes = n * 1024
			}
		}
	}
	p.Command = strings.TrimSpace(strings.ReplaceAll(c.read(dir+"/cmdline"), "\x00", " "))
	if p.Command == "" {
		p.Command = "[" + p.Name + "]"
	}

	if fds, err := os.ReadDir(c.path(dir + "/fd")); err == nil {
		for _, fd := range fds {
			target, err := os.Readlink(c.path(dir + "/fd/" + fd.Name()))
			if inode, ok := strings.CutPrefix(target, "socket:["); err == nil && ok {
				p.sockets = append(p.sockets, strings.TrimSuffix(inode, "]"))
			}
		}
	}
	return p, true
}

func (c *Collector) users() map[string]string {
	users := map[string]string{}
	for line := range strings.Lines(c.read("etc/passwd")) {
		f := strings.Split(line, ":")
		if len(f) > 2 {
			users[f[2]] = f[0]
		}
	}
	return users
}

// ports lists listening TCP sockets and bound, unconnected UDP sockets with their owning Process.
// Owners need read access to other users' /proc/<pid>/fd; without it the port is listed with no owner.
func (c *Collector) ports(procs []procInfo) []snapshot.Port {
	owners := map[string]*snapshot.Owner{}
	for _, p := range procs {
		for _, inode := range p.sockets {
			if _, taken := owners[inode]; !taken {
				owners[inode] = snapshot.ProcessOwner(p.PID, p.Name)
			}
		}
	}
	ports := []snapshot.Port{}
	seen := map[string]bool{}
	for _, table := range []struct{ file, proto, state string }{
		{"proc/net/tcp", "tcp", "0A"}, {"proc/net/tcp6", "tcp", "0A"},
		{"proc/net/udp", "udp", "07"}, {"proc/net/udp6", "udp", "07"},
	} {
		for line := range strings.Lines(c.read(table.file)) {
			f := strings.Fields(line)
			if len(f) < 10 || f[3] != table.state {
				continue
			}
			if table.proto == "udp" && !strings.HasSuffix(f[2], ":0000") {
				continue // connected UDP client socket
			}
			addr, port, ok := parseSocketAddr(f[1])
			if !ok {
				continue
			}
			key := table.proto + addr + ":" + strconv.Itoa(port)
			if seen[key] { // SO_REUSEPORT listeners show up once per socket
				continue
			}
			seen[key] = true
			ports = append(ports, snapshot.Port{Protocol: table.proto, Address: addr, Port: port, Owner: owners[f[9]]})
		}
	}
	slices.SortFunc(ports, func(a, b snapshot.Port) int {
		return cmp.Or(cmp.Compare(a.Port, b.Port), cmp.Compare(a.Protocol, b.Protocol), cmp.Compare(a.Address, b.Address))
	})
	return ports
}

// parseSocketAddr decodes "0100007F:1538" (IPv4) or the 32-hex-digit IPv6 form; each 32-bit word is little-endian.
func parseSocketAddr(s string) (string, int, bool) {
	hexIP, hexPort, ok := strings.Cut(s, ":")
	if !ok {
		return "", 0, false
	}
	raw, err := hex.DecodeString(hexIP)
	if err != nil || (len(raw) != 4 && len(raw) != 16) {
		return "", 0, false
	}
	for i := 0; i < len(raw); i += 4 {
		raw[i], raw[i+1], raw[i+2], raw[i+3] = raw[i+3], raw[i+2], raw[i+1], raw[i]
	}
	port, err := strconv.ParseUint(hexPort, 16, 16)
	if err != nil {
		return "", 0, false
	}
	return net.IP(raw).String(), int(port), true
}
