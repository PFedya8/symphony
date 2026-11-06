package main

import (
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed index.html
var page string

func handler(s *service, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.URL.Path == "/tasks" && r.Method == "GET" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
			io.WriteString(w, page)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/api/v1/control/") {
			http.NotFound(w, r)
			return
		}
		if len(token) < 32 || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
			http.Error(w, "unauthorized", 401)
			return
		}
		view := strings.TrimPrefix(r.URL.Path, "/api/v1/control/")
		req := obj{}
		if view == "commands" {
			if r.Method != "POST" {
				w.WriteHeader(405)
				return
			}
			if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
				w.WriteHeader(415)
				return
			}
			dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
			if dec.Decode(&req) != nil || req == nil {
				http.Error(w, "invalid json", 400)
				return
			}
			if dec.Decode(new(any)) != io.EOF {
				http.Error(w, "invalid json", 400)
				return
			}
			req["scope"] = "control"
			req["actor"] = "demo-operator"
		} else {
			if r.Method != "GET" {
				w.WriteHeader(405)
				return
			}
			if view != "snapshot" && view != "capabilities" && view != "events" {
				http.NotFound(w, r)
				return
			}
			req["op"] = view
			if raw, ok := r.URL.Query()["cursor"]; ok {
				n, err := strconv.ParseInt(raw[0], 10, 53)
				if err != nil {
					n = -1
				}
				req["cursor"] = float64(n)
			}
		}
		result, code := s.request(req)
		w.Header().Set("Content-Type", "application/json")
		if code != "" {
			status := 409
			if code == "forbidden" {
				status = 403
			}
			if code == "storage_unavailable" {
				status = 503
			}
			w.WriteHeader(status)
			result = obj{"error": obj{"code": code}}
		}
		json.NewEncoder(w).Encode(result)
	})
}
func main() {
	token := os.Getenv("SYMPHONY_DEMO_TOKEN")
	path := os.Getenv("SYMPHONY_DEMO_DB")
	if len(token) < 32 || path == "" {
		log.Fatal("set SYMPHONY_DEMO_TOKEN (32+ bytes) and SYMPHONY_DEMO_DB")
	}
	addr := os.Getenv("SYMPHONY_GO_ADDR")
	if addr == "" {
		addr = "127.0.0.1:4001"
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal("listen address must be a literal loopback IP")
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		log.Fatal(err)
	}
	project := os.Getenv("SYMPHONY_PROJECT")
	if project == "" {
		project = "demo"
	}
	s, err := openProject(path, project)
	if err != nil {
		log.Fatal(err)
	}
	defer s.close()
	server := &http.Server{Addr: addr, Handler: handler(s, token), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-stop; server.Close() }()
	log.Printf("fixture simulator listening on %s", addr)
	if err = server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Print(err)
	}
}
