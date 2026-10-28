// Package docker reads running Containers and their resource usage from the Docker Engine API.
package docker

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Container is one running container with raw CPU counters; rates are derived by the caller.
type Container struct {
	ID, Name, Image, Status string
	CPUUsage                uint64 // nanoseconds of CPU used by the container
	SystemCPUUsage          uint64 // nanoseconds of CPU on the host
	OnlineCPUs              int
	MemoryBytes             uint64
	MemoryLimitBytes        uint64
	Ports                   []PublishedPort
}

type PublishedPort struct {
	IP          string
	PublicPort  int
	PrivatePort int
	Protocol    string
}

// String renders the port like `docker ps`: "0.0.0.0:8080->80/tcp" or "443/tcp".
func (p PublishedPort) String() string {
	if p.PublicPort == 0 {
		return fmt.Sprintf("%d/%s", p.PrivatePort, p.Protocol)
	}
	return fmt.Sprintf("%s->%d/%s", net.JoinHostPort(p.IP, fmt.Sprint(p.PublicPort)), p.PrivatePort, p.Protocol)
}

type Client struct{ http *http.Client }

func New(socket string) *Client {
	return &Client{http: &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		}},
	}}
}

func (c *Client) get(ctx context.Context, path string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker"+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// Containers lists running containers and fetches a one-shot stats sample for each in parallel.
func (c *Client) Containers(ctx context.Context) ([]Container, error) {
	var list []struct {
		ID     string `json:"Id"`
		Names  []string
		Image  string
		Status string
		Ports  []struct {
			IP          string
			PrivatePort int
			PublicPort  int
			Type        string
		}
	}
	if err := c.get(ctx, "/containers/json", &list); err != nil {
		return nil, err
	}
	out := make([]Container, len(list))
	var wg sync.WaitGroup
	for i, l := range list {
		out[i] = Container{ID: shortID(l.ID), Image: l.Image, Status: l.Status, Ports: []PublishedPort{}}
		if len(l.Names) > 0 {
			out[i].Name = strings.TrimPrefix(l.Names[0], "/")
		}
		for _, p := range l.Ports {
			out[i].Ports = append(out[i].Ports, PublishedPort{IP: p.IP, PublicPort: p.PublicPort, PrivatePort: p.PrivatePort, Protocol: p.Type})
		}
		wg.Go(func() { c.stats(ctx, l.ID, &out[i]) })
	}
	wg.Wait()
	return out, nil
}

// stats fills usage counters; a container that stops mid-way simply keeps zero usage.
func (c *Client) stats(ctx context.Context, id string, into *Container) {
	var s struct {
		CPUStats struct {
			CPUUsage struct {
				TotalUsage uint64 `json:"total_usage"`
			} `json:"cpu_usage"`
			SystemCPUUsage uint64 `json:"system_cpu_usage"`
			OnlineCPUs     int    `json:"online_cpus"`
		} `json:"cpu_stats"`
		MemoryStats struct {
			Usage uint64            `json:"usage"`
			Limit uint64            `json:"limit"`
			Stats map[string]uint64 `json:"stats"`
		} `json:"memory_stats"`
	}
	if err := c.get(ctx, "/containers/"+id+"/stats?stream=false&one-shot=true", &s); err != nil {
		return
	}
	into.CPUUsage = s.CPUStats.CPUUsage.TotalUsage
	into.SystemCPUUsage = s.CPUStats.SystemCPUUsage
	into.OnlineCPUs = s.CPUStats.OnlineCPUs
	// Same as `docker stats`: page cache that can be reclaimed is not counted as used.
	cache := s.MemoryStats.Stats["inactive_file"]                // cgroup v2
	if v, ok := s.MemoryStats.Stats["total_inactive_file"]; ok { // cgroup v1
		cache = v
	}
	into.MemoryBytes = s.MemoryStats.Usage
	if cache < into.MemoryBytes {
		into.MemoryBytes -= cache
	}
	into.MemoryLimitBytes = s.MemoryStats.Limit
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}
