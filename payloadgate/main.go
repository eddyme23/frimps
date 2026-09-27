package main

import (
	"bufio"
	"bytes"
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

const maxHeader = 32 * 1024
const maxPreface = 64 * 1024

func relay(client net.Conn, reader io.Reader, target string) {
	backend, err := net.Dial("tcp", target)
	if err != nil { log.Printf("connect %s: %v", target, err); return }
	defer backend.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(backend, reader); _ = backend.(*net.TCPConn).CloseWrite() }()
	go func() { defer wg.Done(); _, _ = io.Copy(client, backend) }()
	wg.Wait()
}

func readHeader(reader *bufio.Reader) ([]byte, error) {
	var header []byte
	for len(header) < maxHeader {
		line, err := reader.ReadBytes('\n')
		header = append(header, line...)
		if err != nil { return nil, err }
		if bytes.HasSuffix(header, []byte("\r\n\r\n")) || bytes.HasSuffix(header, []byte("\n\n")) { return header, nil }
	}
	return nil, io.ErrShortBuffer
}

func waitForSSH(reader *bufio.Reader) ([]byte, error) {
	buf := make([]byte, 0, 4096)
	for len(buf) < maxPreface {
		chunk := make([]byte, 2048)
		n, err := reader.Read(chunk)
		if n > 0 {
			buf = append(buf, chunk[:n]...)
			if index := bytes.Index(buf, []byte("SSH-")); index >= 0 { return buf[index:], nil }
		}
		if err != nil { return nil, err }
	}
	return nil, io.ErrShortBuffer
}

func main() {
	listen := flag.String("listen", "127.0.0.1:3102", "payload gateway listener")
	sshTarget := flag.String("ssh-target", "127.0.0.1:143", "raw SSH target")
	wsTarget := flag.String("ws-target", "127.0.0.1:3103", "SSH WebSocket target")
	legacyTarget := flag.String("legacy-target", "127.0.0.1:3104", "GF-compatible legacy payload target")
	flag.Parse()

	listener, err := net.Listen("tcp", *listen)
	if err != nil { log.Fatal(err) }
	log.Printf("payload gateway listening on %s", *listen)
	for {
		client, err := listener.Accept()
		if err != nil { log.Printf("accept: %v", err); continue }
		go func() {
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(30 * time.Second))
			reader := bufio.NewReader(client)
			header, err := readHeader(reader)
			if err != nil { log.Printf("read header: %v", err); return }
			lower := strings.ToLower(string(header))
			if !strings.Contains(lower, "sec-websocket-key:") {
				backend, err := net.Dial("tcp", *legacyTarget)
				if err != nil { log.Printf("connect legacy payload backend: %v", err); return }
				defer backend.Close()
				_, _ = backend.Write(header)
				_ = client.SetDeadline(time.Time{})
				var wg sync.WaitGroup
				wg.Add(2)
				go func() { defer wg.Done(); _, _ = io.Copy(backend, reader); _ = backend.(*net.TCPConn).CloseWrite() }()
				go func() { defer wg.Done(); _, _ = io.Copy(client, backend) }()
				wg.Wait()
				return
			}
			if strings.Contains(lower, "upgrade: websocket") {
				backend, err := net.Dial("tcp", *wsTarget)
				if err != nil { log.Printf("connect websocket backend: %v", err); return }
				defer backend.Close()
				_, _ = backend.Write(header)
				_ = client.SetDeadline(time.Time{})
				var wg sync.WaitGroup
				wg.Add(2)
				go func() { defer wg.Done(); _, _ = io.Copy(backend, reader); _ = backend.(*net.TCPConn).CloseWrite() }()
				go func() { defer wg.Done(); _, _ = io.Copy(client, backend) }()
				wg.Wait()
				return
			}

			// Match the legacy GF proxy behavior for non-WebSocket payloads.
			// CONNECT payloads expect a 200 tunnel response; GET/PATCH-style
			// SSH payloads expect a 101 upgrade response before raw SSH starts.
			if strings.HasPrefix(strings.TrimSpace(strings.ToUpper(string(header))), "CONNECT ") {
				_, _ = io.WriteString(client, "HTTP/1.1 200 Connection established\r\nConnection: keep-alive\r\n\r\n")
			} else {
				_, _ = io.WriteString(client, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
			}
			_ = client.SetDeadline(time.Now().Add(30 * time.Second))
			firstSSH, err := waitForSSH(reader)
			if err != nil { log.Printf("payload did not yield SSH: %v", err); return }
			_ = client.SetDeadline(time.Time{})
			relay(client, io.MultiReader(bytes.NewReader(firstSSH), reader), *sshTarget)
		}()
	}
}
