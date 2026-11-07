package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Run the real main in a child so assertions cover the executable's exit status.
func TestMainProcessHelper(t *testing.T) {
	if os.Getenv("SYMPHONY_TEST_MAIN") != "1" {
		return
	}
	main()
	os.Exit(0)
}

func TestOccupiedPortExitsNonzeroWithoutReadiness(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestMainProcessHelper$")
	command.Env = append(os.Environ(), "SYMPHONY_TEST_MAIN=1", "SYMPHONY_DEMO_TOKEN="+strings.Repeat("t", 32), "SYMPHONY_PROJECT=demo", "SYMPHONY_DEMO_DB="+filepath.Join(t.TempDir(), "state.sqlite"), "SYMPHONY_GO_ADDR="+listener.Addr().String())
	output, err := command.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("server did not fail promptly: %v", ctx.Err())
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() == 0 {
		t.Fatalf("expected nonzero exit, got %v; output: %s", err, output)
	}
	if bytes.Contains(output, []byte("listening on")) {
		t.Fatalf("false readiness: %s", output)
	}
	if !bytes.Contains(output, []byte("listen")) {
		t.Fatalf("missing bind diagnostic: %s", output)
	}
}

func TestBoundServerReadinessAndSignalExit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestMainProcessHelper$")
	token := strings.Repeat("t", 32)
	command.Env = append(os.Environ(), "SYMPHONY_TEST_MAIN=1", "SYMPHONY_DEMO_TOKEN="+token, "SYMPHONY_PROJECT=demo", "SYMPHONY_DEMO_DB="+filepath.Join(t.TempDir(), "state.sqlite"), "SYMPHONY_GO_ADDR=127.0.0.1:0")
	pipe, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = command.Stdout
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { command.Process.Kill(); command.Wait() }()
	lines := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(pipe)
		if scanner.Scan() {
			lines <- scanner.Text()
		}
		close(lines)
	}()
	var line string
	select {
	case line = <-lines:
	case <-ctx.Done():
		t.Fatal("readiness timeout")
	}
	_, addr, ok := strings.Cut(line, "listening on ")
	if !ok || strings.HasSuffix(addr, ":0") {
		t.Fatalf("missing bound address: %s", line)
	}
	request, err := http.NewRequestWithContext(ctx, "GET", "http://"+addr+"/api/v1/control/capabilities", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("readiness without usable API: %d", response.StatusCode)
	}
	if err = command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err = command.Wait(); err != nil {
		t.Fatalf("signal shutdown: %v", err)
	}
}
