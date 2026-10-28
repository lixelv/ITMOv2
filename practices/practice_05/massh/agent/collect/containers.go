package collect

import (
	"cmp"
	"context"
	"slices"
	"time"

	"massh/agent/docker"
	"massh/agent/snapshot"
)

// containers fills s.Docker and makes ports published by a Container belong to it rather than to docker-proxy.
func (c *Collector) containers(cur *sample, s *snapshot.Snapshot) {
	if c.Docker == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	list, err := c.Docker.Containers(ctx)
	if err != nil {
		s.Docker = snapshot.NoDocker()
		return
	}
	cur.containerCPU = map[string][2]uint64{}
	s.Docker = snapshot.Docker{Available: true, Containers: []snapshot.Container{}}
	for _, d := range list {
		cur.containerCPU[d.ID] = [2]uint64{d.CPUUsage, d.SystemCPUUsage}
		out := snapshot.Container{
			ID: d.ID, Name: d.Name, Image: d.Image, Status: d.Status,
			MemoryBytes: d.MemoryBytes, MemoryLimitBytes: d.MemoryLimitBytes, Ports: []string{},
		}
		if c.prev != nil {
			if before, ok := c.prev.containerCPU[d.ID]; ok && d.CPUUsage >= before[0] && d.SystemCPUUsage > before[1] {
				out.CPUPercent = round2(float64(d.CPUUsage-before[0]) / float64(d.SystemCPUUsage-before[1]) * float64(max(d.OnlineCPUs, 1)) * 100)
			}
		}
		for _, p := range d.Ports {
			out.Ports = append(out.Ports, p.String())
			if p.PublicPort != 0 {
				s.Ports = claimPort(s.Ports, p, d.Name)
			}
		}
		s.Docker.Containers = append(s.Docker.Containers, out)
	}
	slices.SortFunc(s.Docker.Containers, func(a, b snapshot.Container) int { return cmp.Compare(a.Name, b.Name) })
	slices.SortFunc(s.Ports, func(a, b snapshot.Port) int {
		return cmp.Or(cmp.Compare(a.Port, b.Port), cmp.Compare(a.Protocol, b.Protocol), cmp.Compare(a.Address, b.Address))
	})
}

// claimPort hands a published port to its Container, adding it when Docker publishes it via iptables only.
func claimPort(ports []snapshot.Port, p docker.PublishedPort, container string) []snapshot.Port {
	owner := snapshot.ContainerOwner(container)
	found := false
	for i := range ports {
		if ports[i].Protocol == p.Protocol && ports[i].Port == p.PublicPort && (p.IP == "" || ports[i].Address == p.IP) {
			ports[i].Owner = owner
			found = true
		}
	}
	if found {
		return ports
	}
	return append(ports, snapshot.Port{Protocol: p.Protocol, Address: cmp.Or(p.IP, "0.0.0.0"), Port: p.PublicPort, Owner: owner})
}
