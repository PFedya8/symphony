package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

var boardStages = []string{"Backlog", "Todo", "In Progress", "Human Review", "Merging", "Done", "Rework", "Canceled", "Duplicate"}

func terminalStage(v any) bool { return v == "Done" || v == "Canceled" || v == "Duplicate" }
func fixtureTask(i, t, p, stage string) obj {
	return obj{"id": i, "title": t, "project": p, "external_id": i, "tracker": "fixture", "description": "Synthetic task. No real code, PR or deployment is implied.", "status": "opened", "stage": stage, "revision": float64(1), "hold": false, "dependencies": []any{}, "release_verified": false, "plan": []any{obj{"text": "Inspect the task and constraints", "completed": false}, obj{"text": "Prepare the change and checks", "completed": false}, obj{"text": "Review evidence before any release", "completed": false}}, "documents": []any{}, "comments": []any{}, "reports": []any{}, "links": []any{}}
}
func migrateBoard(d *state) {
	if d.Tasks == nil {
		d.Tasks = map[string]obj{}
		d.BoardRevision = 1
	}
	for k, v := range fixtureTask(d.Task["id"].(string), d.Task["title"].(string), d.Task["project"].(string), "Todo") {
		if _, ok := d.Task[k]; !ok {
			d.Task[k] = v
		}
	}
	d.Tasks[d.Task["id"].(string)] = d.Task
}
func unScope(d *state) {
	d.Tasks[d.Task["id"].(string)] = d.Task
	if t := d.Tasks["fixture-1"]; t != nil {
		d.Task = t
	}
}
func scopeTask(d *state, req obj) string {
	i, _ := req["task_id"].(string)
	if i == "" {
		if r := find(d, req["run_id"]); r != nil {
			i, _ = r["task_id"].(string)
		}
	}
	if i == "" {
		i = "fixture-1"
		if d.Tasks[i] == nil {
			tasks := boardTasks(*d)
			if len(tasks) > 0 {
				i = tasks[0]["id"].(string)
			}
		}
	}
	if d.Tasks[i] == nil {
		return "not_found"
	}
	d.Task = d.Tasks[i]
	return ""
}
func boardTasks(d state) []obj {
	keys := []string{}
	for k := range d.Tasks {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	tasks := []obj{}
	for _, k := range keys {
		tasks = append(tasks, d.Tasks[k])
	}
	return tasks
}
func taskAttempts(d *state) int {
	n := 0
	for _, r := range d.Runs {
		if r["task_id"] == d.Task["id"] {
			n++
		}
	}
	return n
}
func (s *service) mode() string {
	if s.data.DiscoveryScope != "" {
		return "gitlab_discovery"
	}
	return "fixture"
}
func validText(v any, n int) bool {
	t, ok := v.(string)
	return ok && len(t) > 0 && len(t) <= n && strings.TrimSpace(t) != ""
}
func validURL(v any) bool {
	if !validText(v, 2000) {
		return false
	}
	u, e := url.Parse(v.(string))
	return e == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil
}
func list(t obj, k string) []any {
	v, _ := t[k].([]any)
	if v == nil {
		return []any{}
	}
	return v
}
func actor(req obj) string {
	a, _ := req["actor"].(string)
	if a == "" {
		return "operator"
	}
	return a
}
func authored(req obj) obj {
	return obj{"id": id(), "author": actor(req), "at": time.Now().UTC().Format(time.RFC3339Nano)}
}
func boardTransition(req obj, d *state) (obj, string) {
	op, _ := req["op"].(string)
	t := d.Task
	switch op {
	case "create":
		if d.DiscoveryScope != "" {
			return nil, "runtime_managed"
		}
		if len(d.Tasks) >= 100 {
			return nil, "task_limit"
		}
		if !validText(req["title"], 160) || !validText(req["project"], 80) {
			return nil, "invalid_text"
		}
		desc := req["description"]
		if desc == nil {
			desc = "Manually created fixture task. No real agent is connected."
		}
		if !validText(desc, 4000) {
			return nil, "invalid_text"
		}
		t = fixtureTask("task-"+id(), req["title"].(string), req["project"].(string), "Backlog")
		t["description"] = desc
		d.Task = t
		d.BoardRevision++
		return t, ""
	case "move":
		valid := false
		for _, stage := range boardStages {
			if req["stage"] == stage {
				valid = true
			}
		}
		if !valid {
			return nil, "invalid_stage"
		}
		for _, r := range d.Runs {
			if r["task_id"] == t["id"] && active(r["state"]) {
				return nil, "run_active"
			}
		}
		t["stage"] = req["stage"]
	case "plan":
		if !validText(req["text"], 4000) {
			return nil, "invalid_text"
		}
		plan := []any{}
		for _, line := range strings.Split(req["text"].(string), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			if len(line) > 160 {
				return nil, "invalid_plan"
			}
			plan = append(plan, obj{"text": line, "completed": false})
		}
		if len(plan) < 1 || len(plan) > 20 {
			return nil, "invalid_plan"
		}
		t["plan"] = plan
	case "check":
		step, ok := req["step"].(float64)
		done, b := req["completed"].(bool)
		plan := list(t, "plan")
		if !ok || !b || step < 0 || step != float64(int(step)) || step >= float64(len(plan)) {
			return nil, "invalid_step"
		}
		plan[int(step)].(map[string]any)["completed"] = done
	case "link":
		if req["kind"] != "pull_request" && req["kind"] != "walkthrough" {
			return nil, "invalid_link_kind"
		}
		if !validURL(req["url"]) {
			return nil, "invalid_url"
		}
		if !validText(req["title"], 160) {
			return nil, "invalid_text"
		}
		links := list(t, "links")
		if len(links) >= 10 {
			return nil, "link_limit"
		}
		v := obj{"kind": req["kind"], "url": req["url"], "title": req["title"], "verification": "user supplied; not verified"}
		t["links"] = append(links, v)
		bump(d)
		return v, ""
	case "worklog":
		values := list(t, "documents")
		if len(values) >= 20 {
			return nil, "document_limit"
		}
		sections, code := authoredSections(req)
		if code != "" {
			return nil, code
		}
		v := authored(req)
		v["sections"] = sections
		v["provenance"] = "operator authored"
		t["documents"] = append(values, v)
		bump(d)
		return v, ""
	case "comment":
		values := list(t, "comments")
		if len(values) >= 100 {
			return nil, "comment_limit"
		}
		if !validText(req["text"], 4000) {
			return nil, "invalid_text"
		}
		parent := req["parent_id"]
		if parent == "" {
			parent = nil
		}
		depth := float64(0)
		if parent != nil {
			found := false
			for _, raw := range values {
				c := raw.(map[string]any)
				if c["id"] == parent && c["depth"].(float64) < 2 {
					depth = c["depth"].(float64) + 1
					found = true
				}
			}
			if !found {
				return nil, "invalid_parent"
			}
		}
		v := authored(req)
		v["text"] = req["text"]
		v["parent_id"] = parent
		v["depth"] = depth
		t["comments"] = append(values, v)
		bump(d)
		return v, ""
	case "evidence":
		values := list(t, "reports")
		if len(values) >= 20 {
			return nil, "report_limit"
		}
		if req["provider"] != "github_api" && req["provider"] != "agent_artifact" && req["provider"] != "runtime_snapshot" {
			return nil, "invalid_provider"
		}
		if !validText(req["reference"], 500) || !validText(req["text"], 8000) {
			return nil, "invalid_text"
		}
		if req["url"] != nil && !validURL(req["url"]) {
			return nil, "invalid_url"
		}
		v := authored(req)
		for _, k := range []string{"url", "provider", "reference", "text"} {
			v[k] = req[k]
		}
		v["verification"] = "operator imported; not independently verified by service"
		t["reports"] = append(values, v)
		bump(d)
		return v, ""
	default:
		return nil, "unsupported_command"
	}
	bump(d)
	return t, ""
}
func authoredSections(req obj) ([]any, string) {
	sections := []any{}
	for _, f := range [][2]string{{"plan_text", "Plan"}, {"acceptance_text", "Acceptance Criteria"}, {"validation_text", "Validation"}} {
		if !validText(req[f[0]], 4000) {
			return nil, "invalid_sections"
		}
		nodes := []any{}
		count := 0
		for _, line := range strings.Split(req[f[0]].(string), "\n") {
			if line == "" {
				continue
			}
			count++
			trimmed := strings.TrimLeft(line, " ")
			spaces := len(line) - len(trimmed)
			if count > 50 || spaces > 4 || spaces%2 != 0 || !validText(trimmed, 500) {
				return nil, "invalid_sections"
			}
			var ok bool
			nodes, ok = appendNode(nodes, spaces/2, trimmed)
			if !ok {
				return nil, "invalid_sections"
			}
		}
		sections = append(sections, obj{"title": f[1], "nodes": nodes})
	}
	return sections, ""
}
func appendNode(nodes []any, depth int, text string) ([]any, bool) {
	if depth == 0 {
		return append(nodes, obj{"text": text, "children": []any{}}), true
	}
	if len(nodes) == 0 {
		return nodes, false
	}
	last := nodes[len(nodes)-1].(map[string]any)
	children, ok := appendNode(last["children"].([]any), depth-1, text)
	last["children"] = children
	return nodes, ok
}

var importPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func importIdentity(req obj) (string, string) {
	if req["op"] != "evidence" && req["op"] != "import-receipt" || req["import_intent"] == nil {
		return "", ""
	}
	intent, ok := req["import_intent"].(string)
	if !ok || !importPattern.MatchString(intent) {
		return "", "invalid_import_intent"
	}
	b, _ := json.Marshal([]any{intent, req["task_id"], req["run_id"], req["revision"], actor(req)})
	return fmt.Sprintf("%x", sha256.Sum256(b)), ""
}
func importReceipt(req obj, d *state) (any, string) {
	if req["scope"] != "control" {
		return nil, "forbidden"
	}
	if !validText(req["key"], 100) {
		return nil, "idempotency_key_required"
	}
	identity, code := importIdentity(req)
	if code != "" || identity == "" {
		return nil, "invalid_import_intent"
	}
	old := d.Commands[req["key"].(string)]
	if old == nil {
		return obj{"found": false}, ""
	}
	if old["import_identity"] != identity {
		return nil, "idempotency_conflict"
	}
	return obj{"found": true, "result": old["result"]}, ""
}
