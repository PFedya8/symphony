package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func boardRequest(s *service, task, op string, extra obj) (any, string) {
	s.mu.Lock()
	revision := any(s.data.BoardRevision)
	if op != "create" {
		if value := s.data.Tasks[task]; value != nil {
			revision = value["revision"]
		}
	}
	s.mu.Unlock()
	req := obj{"op": op, "scope": "control", "actor": "test-operator", "task_id": task, "revision": revision, "key": id()}
	for k, v := range extra {
		req[k] = v
	}
	return s.request(req)
}
func boardGood(t *testing.T, s *service, task, op string, extra obj) obj {
	t.Helper()
	value, code := boardRequest(s, task, op, extra)
	if code != "" {
		t.Fatalf("%s %s: %s", task, op, code)
	}
	return value.(obj)
}
func boardReject(t *testing.T, s *service, task, op, want string, extra obj) {
	t.Helper()
	_, code := boardRequest(s, task, op, extra)
	if code != want {
		t.Fatalf("%s %s: got %q want %q", task, op, code, want)
	}
}
func boardCreate(t *testing.T, s *service, title, project string) string {
	t.Helper()
	return boardGood(t, s, "fixture-1", "create", obj{"title": title, "project": project})["id"].(string)
}
func boardSnapshot(t *testing.T, s *service, task string) obj {
	t.Helper()
	value, code := s.request(obj{"op": "snapshot", "task_id": task})
	if code != "" {
		t.Fatal(code)
	}
	return value.(obj)
}

func TestBoardTaskIsolationAndRevisionConflicts(t *testing.T) {
	s := testService(t)
	a := boardCreate(t, s, "Alpha task", "alpha")
	b := boardCreate(t, s, "Beta task", "beta")
	before := boardSnapshot(t, s, b)["task"]
	changed := boardGood(t, s, a, "move", obj{"stage": "Todo"})
	boardGood(t, s, a, "plan", obj{"text": "Inspect\n\n  Implement\nValidate"})
	boardGood(t, s, a, "check", obj{"step": float64(1), "completed": true})
	boardGood(t, s, a, "hold", nil)
	if !reflect.DeepEqual(before, boardSnapshot(t, s, b)["task"]) {
		t.Fatal("task A edit changed task B")
	}
	boardReject(t, s, a, "move", "stale_revision", obj{"stage": "Done", "revision": changed["revision"]})
	boardReject(t, s, a, "move", "invalid_stage", obj{"stage": "Released"})
	boardReject(t, s, "missing", "move", "not_found", obj{"stage": "Todo"})
	snapshot := boardSnapshot(t, s, a)
	if len(snapshot["tasks"].([]obj)) != 3 || snapshot["board_revision"] != float64(3) {
		t.Fatal("board collection/revision incorrect")
	}
	for _, event := range snapshot["events"].([]obj) {
		if event["task_id"] == nil {
			t.Fatal("activity missing task identity")
		}
	}
	if snapshot["task"].(obj)["release_verified"] != false {
		t.Fatal("manual edit falsely verified release")
	}
}
func TestBoardApprovalsBindTasksAndPreserveOtherPreviews(t *testing.T) {
	s := testService(t)
	a := boardCreate(t, s, "A", "project")
	b := boardCreate(t, s, "B", "project")
	approvalA := boardGood(t, s, a, "preview", nil)
	approvalB := boardGood(t, s, b, "preview", nil)
	boardReject(t, s, b, "start", "approval_required", obj{"approval": approvalA["id"]})
	value, code := s.request(obj{"op": "snapshot", "task_id": a, "approval": approvalA["id"]})
	if code != "" || value.(obj)["approval_valid"] != true {
		t.Fatal("other preview invalidated task A")
	}
	value, _ = s.request(obj{"op": "snapshot", "task_id": b, "approval": approvalA["id"]})
	if value.(obj)["approval_valid"] != false {
		t.Fatal("wrong task preview valid")
	}
	boardGood(t, s, a, "hold", nil)
	boardGood(t, s, a, "release-hold", nil)
	boardReject(t, s, a, "start", "approval_required", obj{"approval": approvalA["id"]})
	run := boardGood(t, s, b, "start", obj{"approval": approvalB["id"]})
	boardReject(t, s, a, "preview", "capacity", nil)
	boardReject(t, s, b, "move", "run_active", obj{"stage": "Done"})
	boardGood(t, s, b, "stop", obj{"run_id": run["id"]})
	waitState(t, s, run["id"].(string), "stopped")
}
func TestBoardRunOwnershipWorkerTargetAndPerTaskBudget(t *testing.T) {
	s := testService(t)
	s.duration = time.Hour
	a := boardCreate(t, s, "A", "project")
	b := boardCreate(t, s, "B", "project")
	beforeA := boardSnapshot(t, s, a)["task"]
	approval := boardGood(t, s, b, "preview", nil)
	run := boardGood(t, s, b, "start", obj{"approval": approval["id"]})
	runID := run["id"].(string)
	boardReject(t, s, a, "stop", "invalid_transition", obj{"run_id": runID})
	s.worker(runID, false)
	if !reflect.DeepEqual(beforeA, boardSnapshot(t, s, a)["task"]) {
		t.Fatal("worker modified unrelated task")
	}
	if boardSnapshot(t, s, b)["task"].(obj)["stage"] != "Human Review" {
		t.Fatal("worker did not target owner")
	}
	for attempt := 2; attempt <= 3; attempt++ {
		approval = boardGood(t, s, b, "preview", nil)
		run = boardGood(t, s, b, "retry", obj{"approval": approval["id"], "run_id": runID})
		if run["attempt"] != float64(attempt) || run["task_id"] != b {
			t.Fatal("wrong attempt owner/count")
		}
		s.worker(run["id"].(string), false)
	}
	approval = boardGood(t, s, b, "preview", nil)
	boardReject(t, s, b, "retry", "budget_exhausted", obj{"approval": approval["id"], "run_id": runID})
	approval = boardGood(t, s, a, "preview", nil)
	boardReject(t, s, a, "retry", "invalid_retry", obj{"approval": approval["id"], "run_id": runID})
	run = boardGood(t, s, a, "start", obj{"approval": approval["id"]})
	if run["attempt"] != float64(1) {
		t.Fatal("budget leaked across tasks")
	}
	boardGood(t, s, a, "stop", obj{"run_id": run["id"]})
	waitState(t, s, run["id"].(string), "stopped")
	events := boardSnapshot(t, s, b)["events"].([]obj)
	for _, event := range events {
		if event["op"] == "succeeded" && event["task_id"] != b {
			t.Fatal("worker audit attributed to wrong task")
		}
	}
}
func TestBoardLegacyMigrationAndRestartDurability(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	s, err := openService(path)
	if err != nil {
		t.Fatal(err)
	}
	legacy := obj{"task": obj{"id": "fixture-1", "tracker": "fixture", "project": "demo", "title": "Legacy", "status": "opened", "revision": float64(4), "hold": true, "dependencies": []any{}, "release_verified": false}, "runs": []any{}, "events": []any{}, "commands": obj{}, "approvals": obj{"old": obj{"id": "old", "revision": float64(4)}}}
	body, _ := json.Marshal(legacy)
	if _, err = s.db.Exec("UPDATE demo_state SET version=1,body=? WHERE id=1", string(body)); err != nil {
		t.Fatal(err)
	}
	s.close()
	s, err = openService(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.data.Tasks) != 1 || s.data.Task["revision"] != float64(4) || s.data.Task["hold"] != true || len(s.data.Approvals) != 0 || len(list(s.data.Task, "plan")) != 3 {
		t.Fatal("legacy migration lost state or retained approval")
	}
	a := boardCreate(t, s, "Persistent", "other-project")
	boardGood(t, s, a, "comment", obj{"text": "Remember this"})
	approval := boardGood(t, s, a, "preview", nil)
	run := boardGood(t, s, a, "start", obj{"approval": approval["id"]})
	s.close()
	s, err = openService(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	if len(s.data.Tasks) != 2 || len(list(s.data.Tasks[a], "comments")) != 1 || find(&s.data, run["id"])["state"] != "interrupted" || len(s.data.Approvals) != 0 {
		t.Fatal("restart lost task or resumed run")
	}
	boardReject(t, s, a, "retry", "approval_required", obj{"run_id": run["id"], "approval": approval["id"]})
}
func TestBoardImportReceiptRecoveryAndIdentityIsolation(t *testing.T) {
	s := testService(t)
	a := boardCreate(t, s, "A", "p")
	b := boardCreate(t, s, "B", "p")
	intent := strings.Repeat("a", 64)
	key := "import-key"
	revision := boardSnapshot(t, s, a)["task"].(obj)["revision"]
	req := obj{"scope": "control", "actor": "alice", "op": "evidence", "task_id": a, "revision": revision, "key": key, "provider": "github_api", "reference": "owner/repo#1", "text": "Synthetic imported report", "import_intent": intent}
	value, code := s.request(req)
	if code != "" {
		t.Fatal(code)
	}
	report := value.(obj)
	receipt := obj{"scope": "control", "actor": "alice", "op": "import-receipt", "task_id": a, "revision": revision, "key": key, "import_intent": intent}
	value, code = s.request(receipt)
	if code != "" || value.(obj)["found"] != true || !reflect.DeepEqual(value.(obj)["result"], report) {
		t.Fatal("cannot recover import receipt")
	}
	req["text"] = "Provider changed after first attempt"
	value, code = s.request(req)
	if code != "" || !reflect.DeepEqual(value, report) {
		t.Fatal("stable import did not replay original receipt")
	}
	if len(list(boardSnapshot(t, s, a)["task"].(obj), "reports")) != 1 {
		t.Fatal("import duplicated")
	}
	for _, change := range []obj{{"actor": "bob"}, {"task_id": b}, {"revision": float64(99)}, {"run_id": "other"}, {"import_intent": strings.Repeat("b", 64)}} {
		altered := obj{}
		for k, v := range receipt {
			altered[k] = v
		}
		for k, v := range change {
			altered[k] = v
		}
		if _, code = s.request(altered); code != "idempotency_conflict" {
			t.Fatalf("identity alteration accepted: %#v %s", change, code)
		}
	}
	receipt["key"] = "missing"
	value, code = s.request(receipt)
	if code != "" || value.(obj)["found"] != false {
		t.Fatal("missing receipt wrong")
	}
	receipt["scope"] = "read"
	if _, code = s.request(receipt); code != "forbidden" {
		t.Fatal("receipt not access checked")
	}
	boardReject(t, s, a, "evidence", "invalid_import_intent", obj{"import_intent": "bad"})
}
func TestBoardNestedWorklogsAndInputValidation(t *testing.T) {
	s := testService(t)
	task := "fixture-1"
	valid := obj{"plan_text": "Root\n  Child\n    Grandchild\nSibling", "acceptance_text": "Works", "validation_text": "Synthetic checks"}
	doc := boardGood(t, s, task, "worklog", valid)
	sections := doc["sections"].([]any)
	nodes := sections[0].(obj)["nodes"].([]any)
	if len(sections) != 3 || len(nodes) != 2 || nodes[0].(obj)["children"].([]any)[0].(obj)["children"].([]any)[0].(obj)["text"] != "Grandchild" {
		t.Fatal("nested worklog malformed")
	}
	for _, text := range []string{"  Orphan", "Root\n    Skipped level", "Root\n      Too deep", "Root\n Odd indent", strings.Repeat("x", 501), strings.Repeat("x\n", 51)} {
		values := obj{"plan_text": text, "acceptance_text": "Works", "validation_text": "Checks"}
		boardReject(t, s, task, "worklog", "invalid_sections", values)
	}
	for _, text := range []string{strings.Repeat("x", 161), strings.Repeat("x\n", 21)} {
		boardReject(t, s, task, "plan", "invalid_plan", obj{"text": text})
	}
	boardReject(t, s, task, "check", "invalid_step", obj{"step": 0.5, "completed": true})
	boardReject(t, s, task, "check", "invalid_step", obj{"step": float64(0), "completed": "true"})
	for _, url := range []string{"javascript:alert(1)", "http://example.com", "https://user:secret@example.com", "https:///missing"} {
		boardReject(t, s, task, "link", "invalid_url", obj{"kind": "pull_request", "title": "PR", "url": url})
	}
	boardReject(t, s, task, "link", "invalid_link_kind", obj{"kind": "deployment", "title": "PR", "url": "https://example.com"})
	boardReject(t, s, task, "evidence", "invalid_provider", obj{"provider": "verified_agent"})
	boardReject(t, s, task, "evidence", "invalid_url", obj{"provider": "agent_artifact", "reference": "ref", "text": "report", "url": "file:///tmp/report"})
}
func TestBoardContentLimitsAndCommentDepth(t *testing.T) {
	s := testService(t)
	task := "fixture-1"
	root := boardGood(t, s, task, "comment", obj{"text": "root"})
	child := boardGood(t, s, task, "comment", obj{"text": "child", "parent_id": root["id"]})
	grand := boardGood(t, s, task, "comment", obj{"text": "grandchild", "parent_id": child["id"]})
	boardReject(t, s, task, "comment", "invalid_parent", obj{"text": "too deep", "parent_id": grand["id"]})
	other := boardCreate(t, s, "Other", "p")
	boardReject(t, s, other, "comment", "invalid_parent", obj{"text": "cross task", "parent_id": root["id"]})
	boardReject(t, s, task, "comment", "invalid_text", obj{"text": strings.Repeat("x", 4001)})
	for i := 3; i < 100; i++ {
		boardGood(t, s, task, "comment", obj{"text": fmt.Sprint(i)})
	}
	boardReject(t, s, task, "comment", "comment_limit", obj{"text": "overflow"})
	for i := 0; i < 10; i++ {
		boardGood(t, s, task, "link", obj{"kind": "pull_request", "title": "Synthetic PR", "url": "https://example.com/pr"})
	}
	boardReject(t, s, task, "link", "link_limit", obj{"kind": "pull_request", "title": "overflow", "url": "https://example.com/pr"})
	for i := 0; i < 20; i++ {
		boardGood(t, s, task, "evidence", obj{"provider": "agent_artifact", "reference": "synthetic", "text": "Unverified"})
	}
	boardReject(t, s, task, "evidence", "report_limit", obj{"provider": "agent_artifact", "reference": "synthetic", "text": "overflow"})
	for i := 0; i < 20; i++ {
		boardGood(t, s, task, "worklog", obj{"plan_text": "Plan", "acceptance_text": "Criteria", "validation_text": "Checks"})
	}
	boardReject(t, s, task, "worklog", "document_limit", obj{"plan_text": "Plan", "acceptance_text": "Criteria", "validation_text": "Checks"})
	if boardSnapshot(t, s, task)["task"].(obj)["release_verified"] != false {
		t.Fatal("unverified artifacts falsely verified release")
	}
}
func TestBoardFullHistoryAllowsSafetyAcrossAllTasks(t *testing.T) {
	s := testService(t)
	tasks := []string{"fixture-1"}
	for i := 0; i < 4; i++ {
		tasks = append(tasks, boardCreate(t, s, fmt.Sprint("Task", i), "p"))
	}
	approval := boardGood(t, s, tasks[4], "preview", nil)
	run := boardGood(t, s, tasks[4], "start", obj{"approval": approval["id"]})
	s.mu.Lock()
	for len(s.data.Commands) < 1000 {
		s.data.Commands[fmt.Sprint("fill-", len(s.data.Commands))] = obj{"fingerprint": "synthetic", "result": obj{}}
	}
	s.mu.Unlock()
	for _, task := range tasks {
		boardGood(t, s, task, "hold", nil)
	}
	boardGood(t, s, tasks[4], "stop", obj{"run_id": run["id"]})
	waitState(t, s, run["id"].(string), "stopped")
	for _, task := range tasks {
		boardReject(t, s, task, "release-hold", "demo_history_full", nil)
		boardReject(t, s, task, "hold", "demo_history_full", nil)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.data.Commands) != 1006 {
		t.Fatalf("unexpected bounded safety receipts %d", len(s.data.Commands))
	}
}
func TestBoardCreateLimitAndReplay(t *testing.T) {
	s := testService(t)
	request := obj{"op": "create", "scope": "control", "key": "create-once", "revision": float64(1), "title": "one", "project": "p"}
	first, code := s.request(request)
	if code != "" {
		t.Fatal(code)
	}
	second, code := s.request(request)
	if code != "" || !reflect.DeepEqual(first, second) {
		t.Fatal("create replay not stable")
	}
	for i := 2; i < 100; i++ {
		boardCreate(t, s, fmt.Sprint(i), "p")
	}
	boardReject(t, s, "fixture-1", "create", "task_limit", obj{"title": "overflow", "project": "p"})
	if len(boardSnapshot(t, s, "fixture-1")["tasks"].([]obj)) != 100 {
		t.Fatal("task cap failed")
	}
}
