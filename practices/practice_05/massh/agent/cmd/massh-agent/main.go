// massh-agent streams Snapshots of this Server to massh over WebSocket on 127.0.0.1:12092.
// It is reached only through an SSH tunnel (ADR 0005) and collects nothing while no client is connected.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"massh/agent/collect"
	"massh/agent/docker"
	"massh/agent/stream"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	listen := flag.String("listen", "127.0.0.1:12092", "loopback address to listen on")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	if err := checkLoopback(*listen); err != nil {
		log.Fatal(err)
	}

	collector := &collect.Collector{Root: "/", Version: version, Statfs: collect.Statfs, Docker: docker.New("/var/run/docker.sock")}
	hub := stream.NewHub(collector, time.Second)
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("massh-agent %s listening on %s", version, ln.Addr())
	srv := &http.Server{Handler: hub, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.Serve(ln); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// checkLoopback refuses to expose the Agent on anything but localhost.
func checkLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return fmt.Errorf("refusing to listen on %s: the Agent only listens on loopback", addr)
	}
	return nil
}
