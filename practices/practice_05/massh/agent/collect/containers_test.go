package collect_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"massh/agent/docker"
	"massh/agent/snapshot"
)

type fakeDocker struct {
	containers []docker.Container
	err        error
}

func (f *fakeDocker) Containers(context.Context) ([]docker.Container, error) {
	return f.containers, f.err
}

func webContainer(cpu, system uint64) docker.Container {
	return docker.Container{
		ID: "4f2a9c1b7e3d", Name: "web", Image: "nginx:1.27", Status: "Up 3 hours",
		CPUUsage: cpu, SystemCPUUsage: system, OnlineCPUs: 2,
		MemoryBytes: 52428800, MemoryLimitBytes: 536870912,
		Ports: []docker.PublishedPort{
			{IP: "0.0.0.0", PublicPort: 8765, PrivatePort: 80, Protocol: "tcp"},
			{IP: "0.0.0.0", PublicPort: 9000, PrivatePort: 9000, Protocol: "udp"},
			{PrivatePort: 443, Protocol: "tcp"},
		},
	}
}

func TestContainersAndTheirPorts(t *testing.T) {
	root := fixtureRoot(t)
	c := &clock{time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)}
	fake := &fakeDocker{containers: []docker.Container{webContainer(1_000_000_000, 100_000_000_000)}}
	col := newCollector(root, c)
	col.SkipProcesses = false
	col.Docker = fake
	col.Collect()

	// 0.5 s of container CPU while the host's 2 CPUs advanced 10 s in total: 0.05 * 2 * 100 = 10 %.
	fake.containers = []docker.Container{webContainer(1_500_000_000, 110_000_000_000)}
	c.t = c.t.Add(time.Second)
	s := col.Collect()

	want := snapshot.Docker{Available: true, Containers: []snapshot.Container{{
		ID: "4f2a9c1b7e3d", Name: "web", Image: "nginx:1.27", Status: "Up 3 hours",
		CPUPercent: 10, MemoryBytes: 52428800, MemoryLimitBytes: 536870912,
		Ports: []string{"0.0.0.0:8765->80/tcp", "0.0.0.0:9000->9000/udp", "443/tcp"},
	}}}
	if !reflect.DeepEqual(s.Docker, want) {
		t.Errorf("docker\n got %+v\nwant %+v", s.Docker, want)
	}

	// Port 8765 is in /proc/net/tcp (held by docker-proxy); 9000/udp is published through iptables only.
	web := snapshot.ContainerOwner("web")
	tcp := findPort(s.Ports, "tcp", 8765)
	if tcp == nil || !reflect.DeepEqual(tcp.Owner, web) {
		t.Errorf("published tcp port owner = %+v, want container web", tcp)
	}
	udp := findPort(s.Ports, "udp", 9000)
	if udp == nil || udp.Address != "0.0.0.0" || !reflect.DeepEqual(udp.Owner, web) {
		t.Errorf("published udp port = %+v, want 0.0.0.0 owned by web", udp)
	}
	if findPort(s.Ports, "tcp", 443) != nil {
		t.Error("an unpublished container port is not listening on the Server")
	}
}

func TestDockerUnavailable(t *testing.T) {
	col := newCollector(fixtureRoot(t), &clock{time.Now()})
	col.SkipProcesses = false
	col.Docker = &fakeDocker{err: errors.New("dial unix /var/run/docker.sock: no such file")}
	s := col.Collect()
	if s.Docker.Available || len(s.Docker.Containers) != 0 {
		t.Errorf("docker = %+v, want not available", s.Docker)
	}
	if len(s.Ports) == 0 || len(s.Processes) == 0 {
		t.Error("the rest of the Snapshot still works without Docker")
	}
}

func findPort(ports []snapshot.Port, proto string, port int) *snapshot.Port {
	for i := range ports {
		if ports[i].Protocol == proto && ports[i].Port == port {
			return &ports[i]
		}
	}
	return nil
}
