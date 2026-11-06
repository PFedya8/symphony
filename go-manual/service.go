// Package main implements only Symphony's manual, simulated fixture slice.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type obj = map[string]any
type state struct {
	Task      obj            `json:"task"`
	Runs      []obj          `json:"runs"`
	Events    []obj          `json:"events"`
	Commands  map[string]obj `json:"commands"`
	Approvals map[string]obj `json:"approvals"`
}
type service struct {
	mu       sync.Mutex
	db       *sql.DB
	data     state
	workers  map[string]*time.Timer
	closed   bool
	duration time.Duration
	fault    error
}

func id() string {
	b := make([]byte, 18)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func active(v any) bool                         { return v == "starting" || v == "running" || v == "stopping" }
func openService(path string) (*service, error) { return openProject(path, "demo") }

func openProject(path, project string) (*service, error) {
	if len(project) == 0 || len(project) > 100 {
		return nil, fmt.Errorf("project must contain 1..100 bytes")
	}
	db, err := sql.Open("sqlite3", path+"?_locking_mode=EXCLUSIVE&_synchronous=FULL&_busy_timeout=0")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &service{db: db, workers: map[string]*time.Timer{}, duration: 3 * time.Second}
	fail := func(e error) (*service, error) { db.Close(); return nil, e }
	if _, err = db.Exec("CREATE TABLE IF NOT EXISTS demo_state (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, body TEXT NOT NULL)"); err != nil {
		return fail(err)
	}
	var version int
	var body []byte
	err = db.QueryRow("SELECT version,body FROM demo_state WHERE id=1").Scan(&version, &body)
	if err == sql.ErrNoRows {
		s.data = state{Task: obj{"id": "fixture-1", "tracker": "fixture", "project": project, "external_id": "1", "title": "Simulated timeout change", "status": "opened", "revision": float64(1), "hold": false, "dependencies": []any{}, "release_verified": false}, Runs: []obj{}, Events: []obj{}, Commands: map[string]obj{}, Approvals: map[string]obj{}}
	} else if err != nil {
		return fail(err)
	} else if version != 1 {
		return fail(fmt.Errorf("unsupported schema %d", version))
	} else if err = json.Unmarshal(body, &s.data); err != nil {
		return fail(err)
	}
	if s.data.Task == nil || s.data.Commands == nil || s.data.Approvals == nil {
		return fail(fmt.Errorf("invalid snapshot"))
	}
	if s.data.Task["project"] != project {
		return fail(fmt.Errorf("database belongs to a different project"))
	}
	for _, r := range s.data.Runs {
		if active(r["state"]) {
			r["state"] = "interrupted"
			r["exit_reason"] = "owner_lost; reconciliation required"
		}
	}
	if err = s.save(s.data); err != nil {
		return fail(err)
	}
	return s, nil
}
func (s *service) save(d state) error {
	body, err := json.Marshal(d)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("INSERT OR REPLACE INTO demo_state VALUES(1,1,?)", string(body))
	return err
}
func (s *service) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	for _, t := range s.workers {
		t.Stop()
	}
	s.db.Close()
}
func clone(d state) state {
	b, _ := json.Marshal(d)
	var out state
	_ = json.Unmarshal(b, &out)
	return out
}
func audit(d *state, op, actor string, before any, result obj) {
	cursor := float64(1)
	if len(d.Events) > 0 {
		cursor = d.Events[len(d.Events)-1]["cursor"].(float64) + 1
	}
	d.Events = append(d.Events, obj{"cursor": cursor, "op": op, "actor": actor, "before_revision": before, "after_revision": d.Task["revision"], "result": result, "at": time.Now().UTC().Format(time.RFC3339Nano)})
	if len(d.Events) > 1000 {
		d.Events = d.Events[len(d.Events)-1000:]
	}
}
func bump(d *state) { d.Task["revision"] = d.Task["revision"].(float64) + 1 }
func find(d *state, id any) obj {
	for _, r := range d.Runs {
		if r["id"] == id {
			return r
		}
	}
	return nil
}
func eligible(d *state) string {
	if d.Task["hold"] == true {
		return "held"
	}
	if d.Task["status"] != "opened" {
		return "task_ineligible"
	}
	if len(d.Task["dependencies"].([]any)) > 0 {
		return "dependencies_blocked"
	}
	for _, r := range d.Runs {
		if active(r["state"]) {
			return "capacity"
		}
	}
	return ""
}
func (s *service) request(req obj) (any, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.fault != nil {
		return nil, "storage_unavailable"
	}
	op, _ := req["op"].(string)
	switch op {
	case "capabilities":
		return obj{"simulated": true, "manual": true, "resume": false, "max_agents": 1, "max_attempts": 3}, ""
	case "snapshot":
		d := clone(s.data)
		actions := []string{"preview", "hold"}
		if d.Task["hold"] == true {
			actions = []string{"release-hold"}
		}
		d.Task["allowed_actions"] = actions
		return obj{"task": d.Task, "runs": d.Runs, "events": d.Events}, ""
	case "events":
		cursor := float64(0)
		if v, ok := req["cursor"]; ok {
			var valid bool
			cursor, valid = v.(float64)
			if !valid || cursor < 0 || cursor != float64(int64(cursor)) {
				return nil, "invalid_cursor"
			}
		}
		items := []obj{}
		for _, e := range clone(s.data).Events {
			if e["cursor"].(float64) > cursor {
				items = append(items, e)
				if len(items) == 100 {
					break
				}
			}
		}
		if len(items) > 0 {
			cursor = items[len(items)-1]["cursor"].(float64)
		}
		return obj{"items": items, "cursor": cursor}, ""
	}
	if req["scope"] != "control" {
		return nil, "forbidden"
	}
	if op == "resume" {
		return nil, "resume_not_supported"
	}
	key, ok := req["key"].(string)
	if !ok || len(key) < 1 || len(key) > 100 {
		return nil, "idempotency_key_required"
	}
	fp := obj{}
	for k, v := range req {
		if k != "key" {
			fp[k] = v
		}
	}
	encoded, err := json.Marshal(fp)
	if err != nil {
		return nil, "invalid_request"
	}
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(encoded))
	if old, ok := s.data.Commands[key]; ok {
		if old["fingerprint"] == fingerprint {
			return old["result"], ""
		}
		return nil, "idempotency_conflict"
	}
	if req["revision"] != s.data.Task["revision"] {
		return nil, "stale_revision"
	}
	if req["task_id"] != nil && req["task_id"] != s.data.Task["id"] {
		return nil, "not_found"
	}
	if len(s.data.Commands) >= 1000 {
		return nil, "demo_history_full"
	}
	d := clone(s.data)
	before := d.Task["revision"]
	var result obj
	effect := ""
	runID := ""
	switch op {
	case "preview":
		if code := eligible(&d); code != "" {
			return nil, code
		}
		result = obj{"id": id(), "revision": d.Task["revision"], "expires": float64(time.Now().Unix() + 120), "scope": "fixture-only; no external actions"}
		d.Approvals = map[string]obj{result["id"].(string): result}
	case "start", "retry":
		if code := eligible(&d); code != "" {
			return nil, code
		}
		approvalID, _ := req["approval"].(string)
		approval := d.Approvals[approvalID]
		if approval == nil || approval["revision"] != d.Task["revision"] || approval["expires"].(float64) <= float64(time.Now().Unix()) {
			return nil, "approval_required"
		}
		var parent any
		if op == "retry" {
			r := find(&d, req["run_id"])
			if r == nil || active(r["state"]) {
				return nil, "invalid_retry"
			}
			parent = r["id"]
		}
		if len(d.Runs) > 0 && op != "retry" {
			return nil, "explicit_retry_required"
		}
		if len(d.Runs) >= 3 {
			return nil, "budget_exhausted"
		}
		runID = id()
		result = obj{"id": runID, "task_id": "fixture-1", "attempt": float64(len(d.Runs) + 1), "parent_id": parent, "state": "starting", "created_at": time.Now().UTC().Format(time.RFC3339Nano), "simulated": true, "evidence": nil, "approval": approvalID}
		d.Runs = append(d.Runs, result)
		d.Approvals = map[string]obj{}
		bump(&d)
		effect = "start"
	case "hold", "release-hold":
		d.Task["hold"] = op == "hold"
		bump(&d)
		result = d.Task
	case "stop":
		r := find(&d, req["run_id"])
		if r == nil || !active(r["state"]) {
			return nil, "invalid_transition"
		}
		runID = r["id"].(string)
		r["state"] = "stopping"
		d.Task["hold"] = true
		bump(&d)
		result = obj{"id": runID, "state": "stopping"}
		effect = "stop"
	case "sync":
		result = obj{"simulated": true, "dispatched": false}
	default:
		return nil, "unsupported_command"
	}
	// Serialize command results before worker updates so retries retain the original response.
	resultBytes, _ := json.Marshal(result)
	var frozen obj
	_ = json.Unmarshal(resultBytes, &frozen)
	d.Commands[key] = obj{"fingerprint": fingerprint, "result": frozen}
	actor, _ := req["actor"].(string)
	if actor == "" {
		actor = "operator"
	}
	audit(&d, op, actor, before, frozen)
	if err = s.save(d); err != nil {
		return nil, "storage_unavailable"
	}
	s.data = d
	if effect == "start" {
		s.workers[runID] = time.AfterFunc(s.duration, func() { s.worker(runID, false) })
		go s.started(runID)
	}
	if effect == "stop" {
		if timer := s.workers[runID]; timer != nil {
			timer.Stop()
		}
		go s.worker(runID, true)
	}
	return frozen, ""
}
func (s *service) persistWorker(d state) {
	if err := s.save(d); err != nil {
		s.fault = err
		return
	}
	s.data = d
}
func (s *service) started(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.fault != nil {
		return
	}
	d := clone(s.data)
	r := find(&d, id)
	if r == nil || r["state"] != "starting" {
		return
	}
	r["state"] = "running"
	audit(&d, "simulated_worker_started", "simulator", nil, obj{"id": id})
	s.persistWorker(d)
}
func (s *service) worker(id string, stop bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.fault != nil {
		return
	}
	d := clone(s.data)
	r := find(&d, id)
	if r == nil || !active(r["state"]) {
		return
	}
	status := "succeeded"
	if stop || r["state"] == "stopping" {
		status = "stopped"
	}
	r["state"] = status
	if status == "succeeded" {
		r["evidence"] = obj{"simulated": true, "changed_files": []any{}, "commit_sha": nil, "environment": "fixture", "checks": []string{"simulated completion"}, "risks": []string{"No real code or deployment verified"}}
	}
	audit(&d, status, "simulator", nil, obj{"id": id})
	s.persistWorker(d)
	delete(s.workers, id)
}
