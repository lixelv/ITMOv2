//go:build linux

package collect_test

import (
	"testing"

	"massh/agent/collect"
)

// BenchmarkCollectLive measures one Collect on the real /proc, the Agent's work per second while massh watches.
// Run it on a Linux Server or container: go test -run '^$' -bench CollectLive ./collect
func BenchmarkCollectLive(b *testing.B) {
	col := &collect.Collector{Root: "/", Statfs: collect.Statfs}
	col.Collect()
	b.ReportAllocs()
	for b.Loop() {
		col.Collect()
	}
}
