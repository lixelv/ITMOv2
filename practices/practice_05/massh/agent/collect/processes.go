package collect

import (
	"cmp"
	"encoding/hex"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"massh/agent/snapshot"
)

const (
	pfKthread = 0x00200000 // PF_KTHREAD in /proc/<pid>/stat flags
	clockTick = 100        // USER_HZ on every Linux the Agent supports
)

type procInfo struct {
	snapshot.Process
	ticks uint64
}

// ownerRescan is how often port owners are looked up again even when no new listening socket appeared,
// so owners of sockets handed to another Process do not linger.
const ownerRescan = 30 * time.Second

// procStatic is what does not change while a Process runs; start (jiffies since boot) tells a reused PID apart.
type procStatic struct {
	start         string
	user, command string
}

// processes lists every non-kernel-thread Process. Each second it reads only /proc/<pid>/stat; the user and command
// line are read once per Process.
func (c *Collector) processes(cur *sample) []procInfo {
	entries, err := os.ReadDir(c.path("proc"))
	if err != nil {
		return nil
	}
	cur.procCPU = map[int]uint64{}
	var elapsed float64
	if c.prev != nil {
		elapsed = cur.at.Sub(c.prev.at).Seconds()
	}
	static := make(map[int]procStatic, len(c.static))
	var list []procInfo
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		p, st, ok := c.process(pid)
		if !ok {
			continue
		}
		static[pid] = st
		cur.procCPU[pid] = p.ticks
		if c.prev != nil && elapsed > 0 {
			if before, ok := c.prev.procCPU[pid]; ok && p.ticks >= before {
				p.CPUPercent = round2(float64(p.ticks-before) / clockTick / elapsed * 100)
			}
		}
		list = append(list, p)
	}
	c.static = static // Processes that exited are forgotten
	slices.SortFunc(list, func(a, b procInfo) int { return cmp.Compare(a.PID, b.PID) })
	return list
}

func (c *Collector) process(pid int) (procInfo, procStatic, bool) {
	dir := "proc/" + strconv.Itoa(pid)
	stat := c.read(dir + "/stat")
	open, close := strings.IndexByte(stat, '('), strings.LastIndexByte(stat, ')')
	if open < 0 || close < open {
		return procInfo{}, procStatic{}, false
	}
	f := strings.Fields(stat[close+1:])
	if len(f) < 22 {
		return procInfo{}, procStatic{}, false
	}
	flags, _ := strconv.ParseUint(f[6], 10, 64)
	if flags&pfKthread != 0 {
		return procInfo{}, procStatic{}, false
	}
	utime, _ := strconv.ParseUint(f[11], 10, 64)
	stime, _ := strconv.ParseUint(f[12], 10, 64)
	rss, _ := strconv.ParseUint(f[21], 10, 64)

	p := procInfo{ticks: utime + stime}
	p.PID = pid
	p.Name = stat[open+1 : close]
	p.MemoryBytes = rss * uint64(c.pageSize())

	st, known := c.static[pid]
	if !known || st.start != f[19] {
		st = procStatic{start: f[19]}
		for line := range strings.Lines(c.read(dir + "/status")) {
			if k, v, _ := strings.Cut(line, ":"); k == "Uid" {
				if uid := strings.Fields(v); len(uid) > 0 {
					st.user = cmp.Or(c.passwd()[uid[0]], uid[0])
				}
				break
			}
		}
		st.command = strings.TrimSpace(strings.ReplaceAll(c.read(dir+"/cmdline"), "\x00", " "))
		if st.command == "" {
			st.command = "[" + p.Name + "]"
		}
	}
	p.User, p.Command = st.user, st.command
	return p, st, true
}

func (c *Collector) pageSize() int {
	if c.PageSize > 0 {
		return c.PageSize
	}
	return os.Getpagesize()
}

// passwd maps uids to user names, rereading /etc/passwd only when it changed.
func (c *Collector) passwd() map[string]string {
	info, err := os.Stat(c.path("etc/passwd"))
	if c.users != nil && err == nil && c.usersStat != nil && info.ModTime().Equal(c.usersStat.ModTime()) && info.Size() == c.usersStat.Size() {
		return c.users
	}
	users := map[string]string{}
	for line := range strings.Lines(c.read("etc/passwd")) {
		f := strings.Split(line, ":")
		if len(f) > 2 {
			users[f[2]] = f[0]
		}
	}
	c.users, c.usersStat = users, info
	return users
}

// ports lists listening TCP sockets and bound, unconnected UDP sockets with their owning Process.
// Owners need read access to other users' /proc/<pid>/fd; without it the port is listed with no owner.
// Walking every descriptor of every Process is the costliest read of a Snapshot, so owners are looked up only when
// a listening socket appears that the last walk did not see, and every ownerRescan otherwise.
func (c *Collector) ports(procs []procInfo, now time.Time) []snapshot.Port {
	type listening struct {
		port  snapshot.Port
		inode string
	}
	var found []listening
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
			found = append(found, listening{snapshot.Port{Protocol: table.proto, Address: addr, Port: port}, f[9]})
		}
	}
	stale := c.owners == nil || now.Sub(c.scannedAt) >= ownerRescan
	for _, l := range found {
		stale = stale || !c.scanned[l.inode]
	}
	if stale {
		c.owners = c.socketOwners(procs)
		c.scanned = map[string]bool{}
		for _, l := range found {
			c.scanned[l.inode] = true
		}
		c.scannedAt = now
	}
	ports := make([]snapshot.Port, len(found))
	for i, l := range found {
		ports[i] = l.port
		ports[i].Owner = c.owners[l.inode]
	}
	slices.SortFunc(ports, func(a, b snapshot.Port) int {
		return cmp.Or(cmp.Compare(a.Port, b.Port), cmp.Compare(a.Protocol, b.Protocol), cmp.Compare(a.Address, b.Address))
	})
	return ports
}

// socketOwners maps socket inodes to the first Process holding them, from /proc/<pid>/fd.
func (c *Collector) socketOwners(procs []procInfo) map[string]*snapshot.Owner {
	owners := map[string]*snapshot.Owner{}
	for _, p := range procs {
		dir := "proc/" + strconv.Itoa(p.PID) + "/fd"
		fds, err := os.ReadDir(c.path(dir))
		if err != nil {
			continue
		}
		for _, fd := range fds {
			target, err := os.Readlink(c.path(dir + "/" + fd.Name()))
			inode, ok := strings.CutPrefix(target, "socket:[")
			if err != nil || !ok {
				continue
			}
			inode = strings.TrimSuffix(inode, "]")
			if _, taken := owners[inode]; !taken {
				owners[inode] = snapshot.ProcessOwner(p.PID, p.Name)
			}
		}
	}
	return owners
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
