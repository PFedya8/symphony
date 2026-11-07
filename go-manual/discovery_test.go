package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func discoveryServer(t *testing.T, handler http.HandlerFunc) (*gitLabDiscovery, *httptest.Server) {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	adapter, err := newGitLabDiscovery(server.URL+"/api/v4", "group/project", "synthetic-token")
	if err != nil {
		t.Fatal(err)
	}
	adapter.client.Transport = server.Client().Transport
	return adapter, server
}
func TestGitLabDiscoveryScopeAndNormalization(t *testing.T) {
	calls := 0
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "GET" || r.URL.EscapedPath() != "/api/v4/projects/group%2Fproject/issues" || r.Header.Get("PRIVATE-TOKEN") != "synthetic-token" || r.URL.Query().Get("per_page") != "100" || r.URL.Query().Get("state") != "all" {
			t.Errorf("unexpected scoped request")
		}
		fmt.Fprint(w, `[{"iid":7,"id":123,"project_id":55,"title":"Synthetic issue","description":"Description","state":"opened","labels":["test"],"updated_at":"2026-11-07T00:00:00Z","web_url":"https://gitlab.example/group/project/-/issues/7"},{"iid":8,"title":"Closed","state":"closed"}]`)
	})
	tasks, err := g.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 || len(tasks) != 2 || tasks[0]["id"] != "7" || tasks[0]["external_id"] != "GL-7" || tasks[0]["stage"] != "Todo" || tasks[1]["stage"] != "Done" || tasks[0]["execution_supported"] != false || tasks[0]["source_dispatchable"] != false {
		t.Fatalf("bad normalization: %#v", tasks)
	}
	if tasks[0]["native_ref"].(obj)["project_path"] != "group/project" {
		t.Fatal("project scope missing")
	}
	b, _ := json.Marshal(tasks)
	if strings.Contains(string(b), "synthetic-token") || strings.Contains(g.Scope(), "synthetic-token") {
		t.Fatal("credential leaked")
	}
	old := g.Scope()
	g.token = "new-synthetic-token"
	if old == g.Scope() {
		t.Fatal("rotation not fenced")
	}
	old = g.Scope()
	g.project = "other/project"
	if old == g.Scope() {
		t.Fatal("project not fenced")
	}
	old = g.Scope()
	g.endpoint += "2"
	if old == g.Scope() {
		t.Fatal("endpoint not fenced")
	}
}
func TestGitLabDiscoveryRejectsUnsafeConfiguration(t *testing.T) {
	for _, endpoint := range []string{"http://gitlab.example/api/v4", "https://user:secret@gitlab.example/api/v4", "https://gitlab.example/api/v4?token=x", "https://gitlab.example/api/v4#x", "https://gitlab.example/arbitrary", "https://gitlab.example/a/../api/v4"} {
		if _, err := newGitLabDiscovery(endpoint, "group/project", "token"); err == nil {
			t.Fatalf("accepted endpoint %s", endpoint)
		}
	}
	for _, project := range []string{"", "../other", "group//project", "/group/project", "group/project/", "group/project?x=1", "group/%2Fother", "group/ project"} {
		if _, err := newGitLabDiscovery("https://gitlab.example/api/v4", project, "token"); err == nil {
			t.Fatalf("accepted project %q", project)
		}
	}
	for _, token := range []string{"", "x\r\ny"} {
		if _, err := newGitLabDiscovery("https://gitlab.example/api/v4", "group/project", token); err == nil {
			t.Fatal("accepted invalid token")
		}
	}
}
func TestGitLabDiscoveryDoesNotFollowRedirects(t *testing.T) {
	reached := false
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached = true }))
	defer target.Close()
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, http.StatusFound) })
	_, err := g.Discover(context.Background())
	if err == nil || reached {
		t.Fatal("redirect followed or accepted")
	}
	if strings.Contains(err.Error(), "synthetic-token") || strings.Contains(err.Error(), target.URL) {
		t.Fatal("unsanitized error")
	}
}
func TestGitLabDiscoveryRejectsInvalidOrUnboundedResponses(t *testing.T) {
	cases := []string{`null`, `{}`, `not json`, `[{"iid":0,"title":"bad","state":"opened"}]`, `[{"iid":1,"title":"bad","state":"unknown"}]`, `[{"iid":1,"title":"","state":"opened"}]`, `[{"iid":1,"title":"one","state":"opened"},{"iid":1,"title":"duplicate","state":"opened"}]`, strings.Repeat("x", (2<<20)+1)}
	many := make([]obj, 101)
	for i := range many {
		many[i] = obj{"iid": i + 1, "title": "task", "state": "opened"}
	}
	encoded, _ := json.Marshal(many)
	cases = append(cases, string(encoded))
	for i, body := range cases {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) })
			if _, err := g.Discover(context.Background()); err == nil {
				t.Fatal("accepted invalid response")
			}
		})
	}
}
func TestGitLabDiscoveryErrorsAreSafeAndCancellationWorks(t *testing.T) {
	g, _ := discoveryServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		fmt.Fprint(w, "secret synthetic-token")
	})
	_, err := g.Discover(context.Background())
	if err == nil || err.Error() != "gitlab_unavailable" {
		t.Fatalf("unsafe error: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = g.Discover(ctx); err == nil {
		t.Fatal("cancel ignored")
	}
}
func TestGitLabDiscoveryBoundsContentAndRejectsUnsafeLinks(t *testing.T) {
	g, _ := newGitLabDiscovery("https://gitlab.example/api/v4", "group/project", "token")
	issue := obj{"iid": float64(1), "title": strings.Repeat("界", 200), "description": strings.Repeat("界", 5000), "state": "opened", "web_url": "javascript:alert(1)"}
	task, err := g.normalize(issue)
	if err != nil {
		t.Fatal(err)
	}
	if len([]rune(task["title"].(string))) != 160 || len([]rune(task["description"].(string))) != 4000 || task["source_url"] != "" {
		t.Fatal("content bounds failed")
	}
	first := task["source_digest"]
	issue["description"] = "changed"
	task, _ = g.normalize(issue)
	if first == task["source_digest"] {
		t.Fatal("source change not detected")
	}
}

func TestGitLabDiscoveryRejectsEmptyQueryAndFragmentDelimiters(t *testing.T) {
	for _, suffix := range []string{"?", "#", "?#", "#?", "/?", "/#"} {
		t.Run(suffix, func(t *testing.T) {
			if _, err := newGitLabDiscovery("https://gitlab.example/api/v4"+suffix, "group/project", "synthetic"); err == nil {
				t.Fatal("accepted malformed endpoint delimiter")
			}
		})
	}
}
