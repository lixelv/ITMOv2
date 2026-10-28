// massh-probe runs inside a test Server and prints Agent Snapshots, one compact JSON per line.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/coder/websocket"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:12092", "Agent address")
	n := flag.Int("n", 3, "Snapshots to read")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*n+5)*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws://"+*addr, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial:", err)
		os.Exit(2)
	}
	defer conn.CloseNow()
	for range *n {
		_, data, err := conn.Read(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, "read:", err)
			os.Exit(1)
		}
		var compact bytes.Buffer
		if err := json.Compact(&compact, data); err != nil {
			fmt.Fprintln(os.Stderr, "json:", err)
			os.Exit(1)
		}
		fmt.Println(compact.String())
	}
	conn.Close(websocket.StatusNormalClosure, "")
}
