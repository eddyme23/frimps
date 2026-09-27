// sshws accepts one RFC 6455 WebSocket connection and relays its binary payload
// to a loopback SSH server.  It is intentionally dependency-free and listens
// only on 127.0.0.1; public HTTP routing remains Nginx's responsibility.
package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:3103", "loopback WebSocket listener")
	sshTarget := flag.String("ssh-target", "127.0.0.1:143", "loopback SSH target")
	flag.Parse()

	server := &http.Server{Addr: *listen, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || !strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
			http.Error(w, "WebSocket upgrade required", http.StatusUpgradeRequired)
			return
		}
		client, rw, err := w.(http.Hijacker).Hijack()
		if err != nil { return }
		defer client.Close()
		ssh, err := net.Dial("tcp", *sshTarget)
		if err != nil {
			fmt.Fprint(rw, "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
			rw.Flush()
			return
		}
		defer ssh.Close()

		key := r.Header.Get("Sec-WebSocket-Key")
		if key == "" {
			// Legacy SSH-WebSocket clients used by the previous installer send
			// only an HTTP Upgrade preface, then carry raw SSH bytes.  This is
			// not RFC 6455, but accepting it here keeps those profiles working
			// without weakening the normal RFC 6455 path below.
			fmt.Fprint(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
			if err := rw.Flush(); err != nil { return }
			log.Printf("legacy SSH WebSocket accepted from %s", client.RemoteAddr())
			relayRaw(rw.Reader, ssh, client)
			return
		}

		h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(h[:]))
		if err := rw.Flush(); err != nil { return }

		log.Printf("RFC 6455 SSH WebSocket accepted from %s", client.RemoteAddr())
		errCh := make(chan error, 2)
		go func() { errCh <- relayWebSocketToSSH(rw.Reader, ssh) }()
		go func() { errCh <- relaySSHToWebSocket(ssh, client) }()
		if err := <-errCh; err != nil && err != io.EOF {
			log.Printf("RFC 6455 SSH WebSocket closed for %s: %v", client.RemoteAddr(), err)
		}
	})}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		panic(err)
	}
}

func relayRaw(reader io.Reader, ssh net.Conn, client net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(ssh, reader); _ = ssh.(*net.TCPConn).CloseWrite() }()
	go func() { defer wg.Done(); _, _ = io.Copy(client, ssh) }()
	wg.Wait()
}

func relayWebSocketToSSH(r *bufio.Reader, ssh net.Conn) error {
	for {
		first, err := r.ReadByte(); if err != nil { return err }
		second, err := r.ReadByte(); if err != nil { return err }
		opcode := first & 0x0f
		masked := second&0x80 != 0
		if !masked { return fmt.Errorf("client WebSocket frame is not masked") }
		length, err := frameLength(r, second&0x7f); if err != nil { return err }
		if length > 16*1024*1024 { return fmt.Errorf("WebSocket frame too large") }
		mask := make([]byte, 4); if _, err := io.ReadFull(r, mask); err != nil { return err }
		payload := make([]byte, length); if _, err := io.ReadFull(r, payload); err != nil { return err }
		for i := range payload { payload[i] ^= mask[i%4] }
		switch opcode {
		case 0x2, 0x0: if _, err := ssh.Write(payload); err != nil { return err }
		case 0x8: return io.EOF
		case 0x9: continue // SSH clients do not require an application-level response here.
		default: return fmt.Errorf("unsupported WebSocket opcode %d", opcode)
		}
	}
}

func relaySSHToWebSocket(ssh net.Conn, client net.Conn) error {
	buf := make([]byte, 32*1024)
	for {
		n, err := ssh.Read(buf)
		if n > 0 {
			if writeErr := writeBinaryFrame(client, buf[:n]); writeErr != nil { return writeErr }
		}
		if err != nil { return err }
	}
}

func frameLength(r io.Reader, marker byte) (int, error) {
	switch marker {
	case 126:
		var b [2]byte; if _, err := io.ReadFull(r, b[:]); err != nil { return 0, err }; return int(b[0])<<8 | int(b[1]), nil
	case 127:
		var b [8]byte; if _, err := io.ReadFull(r, b[:]); err != nil { return 0, err }
		if b[0]&0x80 != 0 { return 0, fmt.Errorf("invalid WebSocket length") }
		length := uint64(0); for _, v := range b { length = length<<8 | uint64(v) }
		if length > uint64(^uint(0)>>1) { return 0, fmt.Errorf("WebSocket frame too large") }; return int(length), nil
	default: return int(marker), nil
	}
}

func writeBinaryFrame(w io.Writer, payload []byte) error {
	header := []byte{0x82}
	switch n := len(payload); {
	case n < 126: header = append(header, byte(n))
	case n <= 0xffff: header = append(header, 126, byte(n>>8), byte(n))
	default:
		header = append(header, 127)
		for shift := 56; shift >= 0; shift -= 8 { header = append(header, byte(uint64(n)>>shift)) }
	}
	if _, err := w.Write(header); err != nil { return err }
	_, err := w.Write(payload); return err
}
