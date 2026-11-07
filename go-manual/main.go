package main

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
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
			w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-src https://player.vimeo.com https://www.youtube-nocookie.com; frame-ancestors 'none'; base-uri 'none'")
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
			dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
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
			if taskID := r.URL.Query().Get("task_id"); taskID != "" {
				req["task_id"] = taskID
			}
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
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	token := os.Getenv("SYMPHONY_DEMO_TOKEN")
	path := os.Getenv("SYMPHONY_DEMO_DB")
	if len(token) < 32 || path == "" {
		return errors.New("set SYMPHONY_DEMO_TOKEN (32+ bytes) and SYMPHONY_DEMO_DB")
	}
	addr := os.Getenv("SYMPHONY_GO_ADDR")
	if addr == "" {
		addr = "127.0.0.1:4001"
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return errors.New("listen address must be a literal loopback IP")
	}
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	project := os.Getenv("SYMPHONY_PROJECT")
	if project == "" {
		project = "demo"
	}
	var discovery *gitLabDiscovery
	if mode := os.Getenv("SYMPHONY_GO_MODE"); mode != "" && mode != "fixture" {
		if mode != "gitlab_discovery" {
			return errors.New("unsupported mode; real execution is unavailable")
		}
		discovery, err = newGitLabDiscovery(os.Getenv("SYMPHONY_GITLAB_ENDPOINT"), os.Getenv("SYMPHONY_GITLAB_PROJECT"), os.Getenv("SYMPHONY_GITLAB_TOKEN"))
		if err != nil {
			return err
		}
	}
	s, err := openConfigured(path, project, discovery)
	if err != nil {
		return err
	}
	defer s.close()
	server := &http.Server{Addr: addr, Handler: handler(s, token), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() { <-ctx.Done(); server.Close() }()
	log.Printf("%s board listening on %s", s.mode(), listener.Addr())
	if discovery != nil {
		go s.pollDiscovery(ctx)
	}
	if err = server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}
