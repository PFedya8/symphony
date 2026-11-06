package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func testService(t *testing.T) *service {
	t.Helper()
	s, e := openService(filepath.Join(t.TempDir(), "test.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.close)
	return s
}
func cmd(s *service, op string, extra obj) (any, string) {
	s.mu.Lock()
	rev := s.data.Task["revision"]
	s.mu.Unlock()
	r := obj{"op": op, "scope": "control", "key": id(), "revision": rev}
	for k, v := range extra {
		r[k] = v
	}
	return s.request(r)
}
func good(t *testing.T, s *service, op string, extra obj) obj {
	t.Helper()
	v, c := cmd(s, op, extra)
	if c != "" {
		t.Fatalf("%s: %s", op, c)
	}
	return v.(obj)
}
func reject(t *testing.T, s *service, op, want string, extra obj) {
	t.Helper()
	_, c := cmd(s, op, extra)
	if c != want {
		t.Fatalf("%s: got %s want %s", op, c, want)
	}
}
func waitState(t *testing.T, s *service, id, state string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		got := find(&s.data, id)["state"]
		s.mu.Unlock()
		if got == state {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("did not reach %s", state)
}
func TestLifecycleSafeguards(t *testing.T) {
	s := testService(t)
	s.duration = 20 * time.Millisecond
	reject(t, s, "start", "approval_required", nil)
	reject(t, s, "resume", "resume_not_supported", nil)
	reject(t, s, "sync", "forbidden", obj{"scope": "read"})
	reject(t, s, "sync", "stale_revision", obj{"revision": float64(0)})
	reject(t, s, "sync", "not_found", obj{"task_id": "other"})
	reject(t, s, "sync", "idempotency_key_required", obj{"key": ""})
	good(t, s, "hold", nil)
	reject(t, s, "preview", "held", nil)
	good(t, s, "release-hold", nil)
	for attempt := 1; attempt <= 3; attempt++ {
		a := good(t, s, "preview", nil)
		op := "start"
		extra := obj{"approval": a["id"]}
		if attempt > 1 {
			op = "retry"
			extra["run_id"] = s.data.Runs[0]["id"]
		}
		r := good(t, s, op, extra)
		reject(t, s, "preview", "capacity", nil)
		waitState(t, s, r["id"].(string), "succeeded")
	}
	a := good(t, s, "preview", nil)
	reject(t, s, "start", "explicit_retry_required", obj{"approval": a["id"]})
	reject(t, s, "retry", "budget_exhausted", obj{"approval": a["id"], "run_id": s.data.Runs[0]["id"]})
	reject(t, s, "retry", "invalid_retry", obj{"approval": a["id"], "run_id": "missing"})
}
func TestStopAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sqlite")
	s, e := openService(path)
	if e != nil {
		t.Fatal(e)
	}
	a := good(t, s, "preview", nil)
	r := good(t, s, "start", obj{"approval": a["id"]})
	good(t, s, "stop", obj{"run_id": r["id"]})
	waitState(t, s, r["id"].(string), "stopped")
	reject(t, s, "preview", "held", nil)
	good(t, s, "release-hold", nil)
	a = good(t, s, "preview", nil)
	r = good(t, s, "retry", obj{"approval": a["id"], "run_id": r["id"]})
	s.close()
	s, e = openService(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.close()
	if find(&s.data, r["id"])["state"] != "interrupted" {
		t.Fatal("restart did not reconcile")
	}
	if len(s.data.Events) < 5 {
		t.Fatal("history lost")
	}
}
func TestIdempotencyAndConcurrency(t *testing.T) {
	s := testService(t)
	req := obj{"op": "hold", "scope": "control", "key": "same", "revision": float64(1)}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, c := s.request(req)
			if c != "" {
				t.Error(c)
			}
		}()
	}
	wg.Wait()
	if s.data.Task["revision"] != float64(2) || len(s.data.Events) != 1 {
		t.Fatal("command duplicated")
	}
	reject(t, s, "sync", "idempotency_conflict", obj{"key": "same"})
}
func TestApprovalStaleExpiredAndSingleUse(t *testing.T) {
	s := testService(t)
	a := good(t, s, "preview", nil)
	s.data.Approvals[a["id"].(string)]["expires"] = float64(0)
	reject(t, s, "start", "approval_required", obj{"approval": a["id"]})
	a = good(t, s, "preview", nil)
	good(t, s, "hold", nil)
	good(t, s, "release-hold", nil)
	reject(t, s, "start", "approval_required", obj{"approval": a["id"]})
}
func TestStorageFenceAndProjectIsolation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.sqlite")
	a, e := openProject(path, "alpha")
	if e != nil {
		t.Fatal(e)
	}
	good(t, a, "hold", nil)
	if b, e := openProject(path, "alpha"); e == nil {
		b.close()
		t.Fatal("second owner accepted")
	}
	a.close()
	if b, e := openProject(path, "beta"); e == nil {
		b.close()
		t.Fatal("wrong project accepted")
	}
	a, e = openProject(path, "alpha")
	if e != nil {
		t.Fatal(e)
	}
	defer a.close()
	if a.data.Task["hold"] != true {
		t.Fatal("lost hold")
	}
	b, e := openProject(filepath.Join(t.TempDir(), "b.sqlite"), "beta")
	if e != nil {
		t.Fatal(e)
	}
	defer b.close()
	if b.data.Task["hold"] != false || b.data.Task["project"] != "beta" {
		t.Fatal("project leaked")
	}
}
func TestStorageFailureRollsBack(t *testing.T) {
	s := testService(t)
	s.db.Close()
	reject(t, s, "hold", "storage_unavailable", nil)
	if s.data.Task["hold"] != false || len(s.data.Events) != 0 {
		t.Fatal("failed write changed memory")
	}
}
func TestEventsAndBounds(t *testing.T) {
	s := testService(t)
	for i := 0; i < 105; i++ {
		good(t, s, "sync", nil)
	}
	v, c := s.request(obj{"op": "events", "cursor": float64(0)})
	if c != "" || len(v.(obj)["items"].([]obj)) != 100 || v.(obj)["cursor"] != float64(100) {
		t.Fatal(v, c)
	}
	_, c = s.request(obj{"op": "events", "cursor": -1.0})
	if c != "invalid_cursor" {
		t.Fatal(c)
	}
	for i := 0; i < 1000; i++ {
		s.data.Commands[id()] = obj{}
	}
	reject(t, s, "sync", "demo_history_full", nil)
}
func TestHTTP(t *testing.T) {
	s := testService(t)
	token := strings.Repeat("a", 32)
	h := handler(s, token)
	for _, tc := range []struct {
		method, path, body, auth, ct string
		status                       int
	}{{"GET", "/api/v1/control/snapshot", "", "", "", 401}, {"GET", "/tasks", "", "", "", 200}, {"POST", "/api/v1/control/commands", "null", token, "application/json", 400}, {"POST", "/api/v1/control/commands", "{} {}", token, "application/json", 400}, {"POST", "/api/v1/control/commands", "{}", token, "text/plain", 415}, {"GET", "/api/v1/control/events?cursor=bad", "", token, "", 409}, {"GET", "/api/v1/control/snapshot", "", token, "", 200}, {"POST", "/api/v1/control/snapshot", "", token, "", 405}, {"GET", "/api/v1/control/missing", "", token, "", 404}} {
		r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		r.Header.Set("Authorization", "Bearer "+tc.auth)
		r.Header.Set("Content-Type", tc.ct)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Errorf("%s: %d != %d", tc.path, w.Code, tc.status)
		}
	}
	server := httptest.NewServer(h)
	defer server.Close()
	r, _ := http.NewRequest("GET", server.URL+"/api/v1/control/capabilities", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	res, e := http.DefaultClient.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	var v obj
	if json.NewDecoder(res.Body).Decode(&v) != nil || v["simulated"] != true {
		t.Fatal(v)
	}
}

func TestDurableIdempotency(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sqlite")
	s, e := openService(path)
	if e != nil {
		t.Fatal(e)
	}
	req := obj{"op": "hold", "scope": "control", "key": "durable", "revision": float64(1)}
	first, c := s.request(req)
	if c != "" {
		t.Fatal(c)
	}
	s.close()
	s, e = openService(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.close()
	second, c := s.request(req)
	if c != "" {
		t.Fatal(c)
	}
	a, _ := json.Marshal(first)
	b, _ := json.Marshal(second)
	if string(a) != string(b) || len(s.data.Events) != 1 {
		t.Fatal("replay changed")
	}
}
func TestConcurrentStartsHaveOneOwner(t *testing.T) {
	s := testService(t)
	a := good(t, s, "preview", nil)
	var wg sync.WaitGroup
	var mu sync.Mutex
	accepted := 0
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, code := s.request(obj{"op": "start", "scope": "control", "key": id(), "revision": float64(1), "approval": a["id"]})
			if code == "" {
				mu.Lock()
				accepted++
				mu.Unlock()
			} else if code != "stale_revision" {
				t.Error(code)
			}
		}()
	}
	wg.Wait()
	if accepted != 1 {
		t.Fatalf("%d owners", accepted)
	}
}

func TestAsyncStorageFailureFailsClosed(t *testing.T) {
	s := testService(t)
	s.duration = time.Hour
	a := good(t, s, "preview", nil)
	r := good(t, s, "start", obj{"approval": a["id"]})
	s.mu.Lock()
	s.db.Close()
	s.mu.Unlock()
	s.worker(r["id"].(string), false)
	_, code := s.request(obj{"op": "snapshot"})
	if code != "storage_unavailable" {
		t.Fatal(code)
	}
}

func TestEmergencyControlsAtCapacity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "capacity.sqlite")
	s, err := openService(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { s.close() }()
	s.duration = time.Hour
	// Seed only old command records, then consume the final two slots normally.
	for i := 0; i < 998; i++ {
		s.data.Commands[fmt.Sprintf("old-%d", i)] = obj{"fingerprint": "seed", "result": obj{"simulated": true}}
		s.data.Events = append(s.data.Events, obj{"cursor": float64(i + 1), "op": "sync", "result": obj{}})
	}
	a := good(t, s, "preview", nil)
	r := good(t, s, "start", obj{"approval": a["id"]})
	waitState(t, s, r["id"].(string), "running")
	if len(s.data.Commands) != 1000 {
		t.Fatal("start did not consume final slot")
	}
	reject(t, s, "sync", "demo_history_full", nil)
	hold := obj{"op": "hold", "scope": "control", "key": "emergency-hold", "revision": float64(2)}
	if _, code := s.request(hold); code != "" {
		t.Fatalf("hold at capacity: %s", code)
	}
	reject(t, s, "hold", "demo_history_full", nil)
	stop := obj{"op": "stop", "scope": "control", "key": "emergency-stop", "revision": float64(3), "run_id": r["id"]}
	result, code := s.request(stop)
	if code != "" {
		t.Fatalf("stop at capacity: %s", code)
	}
	waitState(t, s, r["id"].(string), "stopped")
	reject(t, s, "stop", "demo_history_full", obj{"run_id": r["id"]})
	reject(t, s, "release-hold", "demo_history_full", nil)
	if len(s.data.Commands) != 1002 {
		t.Fatal("emergency reserve not bounded")
	}
	s.close()
	s, err = openService(path)
	if err != nil {
		t.Fatal(err)
	}
	replay, code := s.request(stop)
	if code != "" {
		t.Fatal(code)
	}
	b, _ := json.Marshal(result)
	c, _ := json.Marshal(replay)
	if string(b) != string(c) {
		t.Fatal("stop replay changed")
	}
	if _, code = s.request(hold); code != "" {
		t.Fatal("hold replay lost", code)
	}
	if !s.data.Task["hold"].(bool) || find(&s.data, r["id"])["state"] != "stopped" {
		t.Fatal("emergency state not durable")
	}
	if len(s.data.Events) != 1000 {
		t.Fatal("audit retention changed")
	}
	for i := 1; i < len(s.data.Events); i++ {
		if s.data.Events[i]["cursor"].(float64) != s.data.Events[i-1]["cursor"].(float64)+1 {
			t.Fatal("audit cursor discontinuity")
		}
	}
	for _, op := range []string{"hold", "stop", "stopped"} {
		found := false
		for _, event := range s.data.Events {
			if event["op"] == op {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing durable audit %s", op)
		}
	}
	reject(t, s, "stop", "idempotency_conflict", obj{"key": "emergency-stop", "run_id": r["id"]})
}

func TestConcurrentEmergencyStopsAtCapacity(t *testing.T) {
	s := testService(t)
	s.duration = time.Hour
	for i := 0; i < 998; i++ {
		s.data.Commands[fmt.Sprintf("old-%d", i)] = obj{"fingerprint": "seed", "result": obj{}}
	}
	a := good(t, s, "preview", nil)
	r := good(t, s, "start", obj{"approval": a["id"]})
	var wg sync.WaitGroup
	var mu sync.Mutex
	accepted := 0
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, code := s.request(obj{"op": "stop", "scope": "control", "key": id(), "revision": float64(2), "run_id": r["id"]})
			if code == "" {
				mu.Lock()
				accepted++
				mu.Unlock()
			} else if code != "stale_revision" {
				t.Error(code)
			}
		}()
	}
	wg.Wait()
	waitState(t, s, r["id"].(string), "stopped")
	if accepted != 1 || len(s.data.Commands) != 1001 || s.data.Task["hold"] != true {
		t.Fatalf("accepted=%d count=%d", accepted, len(s.data.Commands))
	}
	reject(t, s, "hold", "demo_history_full", nil)
	reject(t, s, "stop", "demo_history_full", obj{"run_id": r["id"]})
}
