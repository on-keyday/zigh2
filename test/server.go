package main

import (
	"crypto/tls"
	"embed"
	"log"
	"net/http"
)

//go:embed cert/*
var fs embed.FS

func mustRead(name string) []byte {
	d, err := fs.ReadFile("cert/" + name)
	if err != nil {
		panic(err)
	}
	return d
}

func main() {
	cert := mustRead("server.crt")
	key := mustRead("server.key")
	intermediate := mustRead("intermediate_ca.crt")
	pair, err := tls.X509KeyPair(append(cert, intermediate...), key)
	if err != nil {
		panic(err)
	}
	server := http.Server{}
	lis, err := tls.Listen("tcp", ":443", &tls.Config{
		Certificates: []tls.Certificate{pair},
		NextProtos:   []string{"h2"},
	})
	if err != nil {
		panic(err)
	}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Print(r.RemoteAddr, " ", r.Method, " ", r.URL)
		w.Write([]byte("Hello, world!"))
	})
	server.Serve(lis)
}
