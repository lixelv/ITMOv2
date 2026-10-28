// Package stream serves Snapshots over WebSocket, collecting only while at least one client is connected.
package stream

import (
	"context"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"

	"massh/agent/snapshot"
)

type Source interface {
	Collect() snapshot.Snapshot
	// Reset drops the previous sample; called when collection starts again after an idle period.
	Reset()
}

type Hub struct {
	source   Source
	interval time.Duration

	mu      sync.Mutex
	clients map[chan []byte]struct{}
	stop    context.CancelFunc

	// sourceMu serialises access to source when a stopping run overlaps the next one.
	sourceMu sync.Mutex
}

func NewHub(source Source, interval time.Duration) *Hub {
	return &Hub{source: source, interval: interval, clients: map[chan []byte]struct{}{}}
}

func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	ctx := conn.CloseRead(r.Context())

	ch := h.join()
	defer h.leave(ch)
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-ch:
			wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := conn.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (h *Hub) join() chan []byte {
	ch := make(chan []byte, 1)
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[ch] = struct{}{}
	if h.stop == nil {
		ctx, cancel := context.WithCancel(context.Background())
		h.stop = cancel
		go h.run(ctx)
	}
	return ch
}

func (h *Hub) leave(ch chan []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, ch)
	if len(h.clients) == 0 && h.stop != nil {
		h.stop()
		h.stop = nil
	}
}

// run collects and broadcasts until ctx is cancelled by the last client leaving.
func (h *Hub) run(ctx context.Context) {
	h.sourceMu.Lock()
	h.source.Reset()
	h.source.Collect() // prime counters so the first Snapshot already has rates
	h.sourceMu.Unlock()
	warmup := min(h.interval, 250*time.Millisecond)
	timer := time.NewTimer(warmup)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			h.mu.Lock()
			idle := h.stop == nil
			h.mu.Unlock()
			if idle { // keep no state while nobody is watching
				h.sourceMu.Lock()
				h.source.Reset()
				h.sourceMu.Unlock()
			}
			return
		case <-timer.C:
		}
		timer.Reset(h.interval)
		h.sourceMu.Lock()
		s := h.source.Collect()
		h.sourceMu.Unlock()
		data, err := s.Encode()
		if err != nil {
			log.Printf("encode snapshot: %v", err)
			continue
		}
		h.broadcast(data)
	}
}

func (h *Hub) broadcast(data []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.clients {
		select {
		case <-ch: // a slow client only ever gets the newest Snapshot
		default:
		}
		ch <- data
	}
}
