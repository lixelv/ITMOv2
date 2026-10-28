// Package snapshot defines the Snapshot wire format shared with MasshCore.
// Reference JSON lives in contract/fixtures; any shape change bumps FormatVersion.
package snapshot

import (
	"bytes"
	"encoding/json"
	"time"
)

// FormatVersion is the version of the Snapshot shape this Agent produces.
const FormatVersion = 2

type Snapshot struct {
	FormatVersion int       `json:"formatVersion"`
	AgentVersion  string    `json:"agentVersion"`
	Time          time.Time `json:"time"`
	Overview      Overview  `json:"overview"`
	Ports         []Port    `json:"ports"`
	Processes     []Process `json:"processes"`
	Docker        Docker    `json:"docker"`
}

type Overview struct {
	OS            string     `json:"os"`
	Kernel        string     `json:"kernel"`
	UptimeSeconds int64      `json:"uptimeSeconds"`
	LoadAverage   [3]float64 `json:"loadAverage"`
	CPU           CPU        `json:"cpu"`
	Memory        Usage      `json:"memory"`
	Swap          Usage      `json:"swap"`
	Disks         []Disk     `json:"disks"`
	Network       Network    `json:"network"`
}

type CPU struct {
	Model          string    `json:"model"`
	Cores          int       `json:"cores"`
	UsagePercent   float64   `json:"usagePercent"`
	PerCorePercent []float64 `json:"perCorePercent"`
}

type Usage struct {
	TotalBytes uint64 `json:"totalBytes"`
	UsedBytes  uint64 `json:"usedBytes"`
}

type Disk struct {
	MountPoint string `json:"mountPoint"`
	TotalBytes uint64 `json:"totalBytes"`
	UsedBytes  uint64 `json:"usedBytes"`
}

type Network struct {
	RxBytesPerSecond uint64 `json:"rxBytesPerSecond"`
	TxBytesPerSecond uint64 `json:"txBytesPerSecond"`
}

type Port struct {
	Protocol string `json:"protocol"`
	Address  string `json:"address"`
	Port     int    `json:"port"`
	Owner    *Owner `json:"owner"`
}

// Owner is the Process or Container holding a port; nil when unknown.
type Owner struct {
	Kind string `json:"kind"`
	PID  int    `json:"pid,omitempty"`
	Name string `json:"name"`
}

func ProcessOwner(pid int, name string) *Owner { return &Owner{Kind: "process", PID: pid, Name: name} }
func ContainerOwner(name string) *Owner        { return &Owner{Kind: "container", Name: name} }

type Process struct {
	PID         int     `json:"pid"`
	Name        string  `json:"name"`
	User        string  `json:"user"`
	CPUPercent  float64 `json:"cpuPercent"`
	MemoryBytes uint64  `json:"memoryBytes"`
	Command     string  `json:"command"`
}

type Docker struct {
	Available  bool        `json:"available"`
	Containers []Container `json:"containers"`
}

// NoDocker reports that Docker is not installed or not reachable on the Server.
func NoDocker() Docker { return Docker{Available: false, Containers: []Container{}} }

type Container struct {
	ID               string   `json:"id"`
	Name             string   `json:"name"`
	Image            string   `json:"image"`
	Status           string   `json:"status"`
	CPUPercent       float64  `json:"cpuPercent"`
	MemoryBytes      uint64   `json:"memoryBytes"`
	MemoryLimitBytes uint64   `json:"memoryLimitBytes"`
	Ports            []string `json:"ports"`
}

// Encode renders the Snapshot in the canonical indented form used by the fixtures.
// Nil lists are encoded as empty lists so clients never see null collections.
func (s Snapshot) Encode() ([]byte, error) {
	s.normalize()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(s); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func (s *Snapshot) normalize() {
	s.Time = s.Time.UTC()
	if s.Overview.CPU.PerCorePercent == nil {
		s.Overview.CPU.PerCorePercent = []float64{}
	}
	if s.Overview.Disks == nil {
		s.Overview.Disks = []Disk{}
	}
	if s.Ports == nil {
		s.Ports = []Port{}
	}
	if s.Processes == nil {
		s.Processes = []Process{}
	}
	if s.Docker.Containers == nil {
		s.Docker.Containers = []Container{}
	}
	for i := range s.Docker.Containers {
		if s.Docker.Containers[i].Ports == nil {
			s.Docker.Containers[i].Ports = []string{}
		}
	}
}
