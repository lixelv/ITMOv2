package snapshot_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"massh/agent/snapshot"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "contract", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func normal() snapshot.Snapshot {
	return snapshot.Snapshot{
		FormatVersion: snapshot.FormatVersion,
		AgentVersion:  "0.1.0",
		Time:          time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC),
		Overview: snapshot.Overview{
			OS:            "Ubuntu 24.04.1 LTS",
			Kernel:        "6.8.0-45-generic",
			UptimeSeconds: 864210,
			LoadAverage:   [3]float64{0.42, 0.35, 0.3},
			CPU: snapshot.CPU{
				Model:          "AMD EPYC 7763 64-Core Processor",
				Cores:          2,
				UsagePercent:   23.5,
				PerCorePercent: []float64{30, 17},
			},
			Memory: snapshot.Usage{TotalBytes: 4110417920, UsedBytes: 1824522240},
			Swap:   snapshot.Usage{TotalBytes: 2147479552, UsedBytes: 0},
			Disks: []snapshot.Disk{
				{MountPoint: "/", TotalBytes: 41555521536, UsedBytes: 12884901888},
				{MountPoint: "/boot", TotalBytes: 1023303680, UsedBytes: 183500800},
			},
			Network: snapshot.Network{RxBytesPerSecond: 15360, TxBytesPerSecond: 4096},
		},
		Ports: []snapshot.Port{
			{Protocol: "tcp", Address: "0.0.0.0", Port: 22, Owner: snapshot.ProcessOwner(812, "sshd")},
			{Protocol: "tcp", Address: "0.0.0.0", Port: 8080, Owner: snapshot.ContainerOwner("web")},
			{Protocol: "udp", Address: "127.0.0.53", Port: 53},
		},
		Processes: []snapshot.Process{
			{PID: 1, Name: "systemd", User: "root", CPUPercent: 0, MemoryBytes: 13238272, Command: "/sbin/init"},
			{PID: 812, Name: "sshd", User: "root", CPUPercent: 0.5, MemoryBytes: 9437184, Command: "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"},
			{PID: 2045, Name: "postgres", User: "postgres", CPUPercent: 12.25, MemoryBytes: 268435456, Command: "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main"},
		},
		Docker: snapshot.Docker{
			Available: true,
			Containers: []snapshot.Container{{
				ID: "4f2a9c1b7e3d", Name: "web", Image: "nginx:1.27", Status: "Up 3 hours",
				CPUPercent: 1.5, MemoryBytes: 52428800, MemoryLimitBytes: 536870912,
				Ports: []string{"0.0.0.0:8080->80/tcp"},
			}},
		},
	}
}

func TestSerializesToFixtures(t *testing.T) {
	noDocker := normal()
	noDocker.Ports = noDocker.Ports[:1:1]
	noDocker.Ports = append(noDocker.Ports, normal().Ports[2])
	noDocker.Docker = snapshot.NoDocker()

	empty := normal()
	empty.Overview.Disks = []snapshot.Disk{}
	empty.Ports = []snapshot.Port{}
	empty.Processes = []snapshot.Process{}
	empty.Docker = snapshot.Docker{Available: true, Containers: []snapshot.Container{}}

	cases := map[string]snapshot.Snapshot{
		"normal.json":    normal(),
		"no-docker.json": noDocker,
		"empty.json":     empty,
	}
	for name, s := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := s.Encode()
			if err != nil {
				t.Fatal(err)
			}
			if want := fixture(t, name); string(got) != string(want) {
				t.Errorf("encoded snapshot differs from %s\n--- got\n%s\n--- want\n%s", name, got, want)
			}
		})
	}
}

func TestNilSlicesEncodeAsEmptyLists(t *testing.T) {
	got, err := snapshot.Snapshot{Docker: snapshot.NoDocker()}.Encode()
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"disks": []`, `"ports": []`, `"processes": []`, `"containers": []`, `"perCorePercent": []`} {
		if !strings.Contains(string(got), field) {
			t.Errorf("expected %s in\n%s", field, got)
		}
	}
}
