package main

import (
	"context"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestDiscoveryBoardPersistenceIsolationAndExecutionFence(t *testing.T) {
	var phase atomic.Int32
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch phase.Load() {
		case 1:
			fmt.Fprint(w, `[{"iid":7,"title":"Updated","state":"closed"}]`)
		case 2:
			http.Error(w, "secret-provider-error", 500)
		case 3:
			fmt.Fprint(w, `[]`)
		default:
			fmt.Fprint(w, `[{"iid":7,"title":"Initial","state":"opened"}]`)
		}
	})
	path := filepath.Join(t.TempDir(), "gitlab.sqlite")
	s, err := openConfigured(path, "isolated", g)
	if err != nil {
		t.Fatal(err)
	}
	v, code := s.request(obj{"op": "snapshot"})
	if code != "" || v.(obj)["task"] != nil || len(v.(obj)["tasks"].([]obj)) != 0 {
		t.Fatal(v, code)
	}
	s.refreshDiscovery(context.Background())
	for _, op := range []string{"preview", "start", "retry"} {
		_, code = s.request(obj{"op": op, "scope": "control", "key": id(), "revision": float64(1), "task_id": "7"})
		if code != "runtime_unavailable" {
			t.Fatal(op, code)
		}
	}
	_, code = s.request(obj{"op": "runtime-start", "scope": "control", "key": id(), "revision": float64(1), "task_id": "7"})
	if code != "unsupported_command" {
		t.Fatal(code)
	}
	req := obj{"op": "comment", "scope": "control", "actor": "test", "key": "comment", "revision": float64(1), "task_id": "7", "text": "Preserve authored text"}
	if _, code = s.request(req); code != "" {
		t.Fatal(code)
	}
	phase.Store(1)
	s.refreshDiscovery(context.Background())
	v, code = s.request(obj{"op": "snapshot", "task_id": "7"})
	task := v.(obj)["task"].(obj)
	if code != "" || task["stage"] != "Done" || task["revision"] != float64(3) || len(task["comments"].([]any)) != 1 || task["release_verified"] != false {
		t.Fatal(v, code)
	}
	phase.Store(2)
	s.refreshDiscovery(context.Background())
	v, code = s.request(obj{"op": "snapshot"})
	if v.(obj)["runtime_error"] != "gitlab_unavailable" {
		t.Fatal(v, code)
	}
	// Receipt replay never needs provider availability or a current revision.
	if _, code = s.request(req); code != "" {
		t.Fatal(code)
	}
	phase.Store(3)
	s.refreshDiscovery(context.Background())
	if len(s.data.Tasks) != 1 {
		t.Fatal("absence deleted task")
	}
	s.close()
	s, err = openConfigured(path, "isolated", g)
	if err != nil {
		t.Fatal(err)
	}
	s.close()
	if wrong, err := openProject(path, "isolated"); err == nil {
		wrong.close()
		t.Fatal("discovery DB opened as fixture")
	}
	g.token = "rotated"
	if wrong, err := openConfigured(path, "isolated", g); err == nil {
		wrong.close()
		t.Fatal("credential rotation accepted")
	}
}
func TestDiscoveryRejectsFixtureDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fixture.sqlite")
	s, err := openProject(path, "demo")
	if err != nil {
		t.Fatal(err)
	}
	s.close()
	g, _ := newGitLabDiscovery("https://gitlab.example/api/v4", "group/project", strings.Repeat("s", 32))
	if wrong, err := openConfigured(path, "demo", g); err == nil {
		wrong.close()
		t.Fatal("fixture scope changed")
	}
}

func TestDiscoverySourceTransitionsAndLocalStages(t *testing.T) {
	var phase atomic.Int32
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) {
		status := "opened"
		if phase.Load() == 1 || phase.Load() == 2 {
			status = "closed"
		}
		fmt.Fprintf(w, `[{"iid":7,"title":"Version %d","state":%q}]`, phase.Load(), status)
	})
	path := filepath.Join(t.TempDir(), "state.sqlite")
	s, err := openConfigured(path, "demo", g)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { s.close() }()
	check := func(status, stage string, revision float64) {
		t.Helper()
		task := boardSnapshot(t, s, "7")["task"].(obj)
		if task["status"] != status || task["source_state"] != status || task["stage"] != stage || task["revision"] != revision || task["release_verified"] != false {
			t.Fatalf("unexpected task: %#v", task)
		}
	}
	s.refreshDiscovery(context.Background())
	check("opened", "Todo", 1)
	boardGood(t, s, "7", "move", obj{"stage": "Human Review"})
	check("opened", "Human Review", 2)
	phase.Store(1)
	s.refreshDiscovery(context.Background())
	check("closed", "Done", 3)
	boardGood(t, s, "7", "move", obj{"stage": "Rework"})
	check("closed", "Rework", 4)
	// Metadata changes and unchanged polls preserve locally authored stage choices.
	phase.Store(2)
	s.refreshDiscovery(context.Background())
	check("closed", "Rework", 5)
	s.refreshDiscovery(context.Background())
	check("closed", "Rework", 5)
	// A source reopening overrides the local stage and remains durable across restart.
	phase.Store(3)
	s.refreshDiscovery(context.Background())
	check("opened", "Todo", 6)
	s.close()
	s, err = openConfigured(path, "demo", g)
	if err != nil {
		t.Fatal(err)
	}
	check("opened", "Todo", 6)
	boardGood(t, s, "7", "move", obj{"stage": "Done"})
	check("opened", "Done", 7)
	phase.Store(4)
	s.refreshDiscovery(context.Background())
	check("opened", "Done", 8)
	// Capture the originally reported default closed -> reopened path too.
	phase.Store(1)
	s.refreshDiscovery(context.Background())
	check("closed", "Done", 9)
	phase.Store(3)
	s.refreshDiscovery(context.Background())
	check("opened", "Todo", 10)
}

func TestDiscoveryReopensDoneIssue(t *testing.T) {
	var reopened atomic.Bool
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) {
		status := "closed"
		if reopened.Load() {
			status = "opened"
		}
		fmt.Fprintf(w, `[{"iid":7,"title":"Issue","state":%q}]`, status)
	})
	s, err := openConfigured(filepath.Join(t.TempDir(), "state.sqlite"), "demo", g)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	s.refreshDiscovery(context.Background())
	reopened.Store(true)
	s.refreshDiscovery(context.Background())
	task := boardSnapshot(t, s, "7")["task"].(obj)
	if task["stage"] != "Todo" || task["status"] != "opened" {
		t.Fatalf("reopened source remained at stage=%v status=%v", task["stage"], task["status"])
	}
}
