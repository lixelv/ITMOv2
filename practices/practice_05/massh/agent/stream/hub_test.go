package stream_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"massh/agent/snapshot"
	"massh/agent/stream"
)

type countingSource struct {
	collects atomic.Int64
	resets   atomic.Int64
}

func (s *countingSource) Collect() snapshot.Snapshot {
	n := s.collects.Add(1)
	return snapshot.Snapshot{FormatVersion: snapshot.FormatVersion, AgentVersion: "test", Overview: snapshot.Overview{UptimeSeconds: n}}
}

func (s *countingSource) Reset() { s.resets.Add(1) }

func start(t *testing.T, src stream.Source) (url string) {
	t.Helper()
	hub := stream.NewHub(src, 20*time.Millisecond)
	srv := httptest.NewServer(hub)
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func readSnapshot(t *testing.T, conn *websocket.Conn) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	typ, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if typ != websocket.MessageText || !strings.Contains(string(data), `"formatVersion": 2`) {
		t.Fatalf("unexpected message %v %s", typ, data)
	}
	return string(data)
}

func TestIdleHubCollectsNothing(t *testing.T) {
	src := &countingSource{}
	start(t, src)
	time.Sleep(150 * time.Millisecond)
	if n := src.collects.Load(); n != 0 {
		t.Fatalf("collected %d times without clients", n)
	}
}

func TestClientsReceiveStreamUntilTheyLeave(t *testing.T) {
	src := &countingSource{}
	url := start(t, src)

	a, b := dial(t, url), dial(t, url)
	for range 3 {
		readSnapshot(t, a)
		readSnapshot(t, b)
	}

	a.Close(websocket.StatusNormalClosure, "")
	readSnapshot(t, b) // the other client keeps receiving
	b.Close(websocket.StatusNormalClosure, "")

	time.Sleep(100 * time.Millisecond)
	stopped := src.collects.Load()
	time.Sleep(150 * time.Millisecond)
	if n := src.collects.Load(); n != stopped {
		t.Fatalf("kept collecting after the last client left: %d -> %d", stopped, n)
	}
	if src.resets.Load() == 0 {
		t.Fatal("source was never reset, the previous sample would leak into the next session")
	}

	// A new client restarts collection.
	c := dial(t, url)
	defer c.Close(websocket.StatusNormalClosure, "")
	readSnapshot(t, c)
}
