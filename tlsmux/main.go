package main

import (
	"bufio"
	"crypto/tls"
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"sync"
)

func proxy(client net.Conn, reader io.Reader, target string) {
	backend, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("connect %s: %v", target, err)
		_ = client.Close()
		return
	}
	defer backend.Close()
	defer client.Close()

	var copies sync.WaitGroup
	copies.Add(2)
	go func() { defer copies.Done(); _, _ = io.Copy(backend, reader); _ = backend.(*net.TCPConn).CloseWrite() }()
	go func() { defer copies.Done(); _, _ = io.Copy(client, backend) }()
	copies.Wait()
}

func main() {
	listen := flag.String("listen", "127.0.0.1:9443", "TLS listener")
	certPath := flag.String("cert", "/etc/certificates/main.crt", "certificate file")
	keyPath := flag.String("key", "/etc/certificates/main.key", "private key file")
	sshTarget := flag.String("ssh-target", "127.0.0.1:143", "raw SSH target")
	httpTarget := flag.String("http-target", "127.0.0.1:9080", "HTTP/HTTP2 target")
	flag.Parse()

	cert, err := tls.LoadX509KeyPair(*certPath, *keyPath)
	if err != nil { log.Fatal(err) }
	listener, err := tls.Listen("tcp", *listen, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil { log.Fatal(err) }
	log.Printf("tlsmux listening on %s", *listen)

	for {
		conn, err := listener.Accept()
		if err != nil { log.Printf("accept: %v", err); continue }
		go func(c net.Conn) {
			defer func() { _ = c.Close() }()
			reader := bufio.NewReader(c)
			prefix, err := reader.Peek(4)
			if err != nil { log.Printf("read initial stream: %v", err); return }
			target := *httpTarget
			if strings.HasPrefix(string(prefix), "SSH-") { target = *sshTarget }
			proxy(c, reader, target)
		}(conn)
	}
}
