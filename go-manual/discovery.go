package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// gitLabDiscovery is a read-only source adapter. It cannot execute work or mutate
// GitLab. Credentials remain in memory and never appear in its public results.
// Construct a new adapter after configuration changes; persisted Scope fencing
// must be checked by the service before ingesting its results.
type gitLabDiscovery struct {
	endpoint string
	project  string
	token    string
	client   *http.Client
}

func newGitLabDiscovery(endpoint, project, token string) (*gitLabDiscovery, error) {
	u, err := url.Parse(endpoint)
	// Reject delimiters even when their value is empty: url.Parse drops a bare
	// fragment, and appending a resource to a query changes the request path.
	if err != nil || strings.ContainsAny(endpoint, "?#") || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" || !strings.HasSuffix(strings.TrimRight(u.Path, "/"), "/api/v4") {
		return nil, errors.New("invalid_gitlab_endpoint")
	}
	if strings.Contains(u.Path, "//") || strings.Contains(u.Path, "/../") || strings.Contains(u.Path, "/./") {
		return nil, errors.New("invalid_gitlab_endpoint")
	}
	if project == "" || len(project) > 300 || strings.TrimSpace(project) != project {
		return nil, errors.New("invalid_gitlab_project")
	}
	for _, part := range strings.Split(project, "/") {
		if part == "" || part == "." || part == ".." {
			return nil, errors.New("invalid_gitlab_project")
		}
		for _, r := range part {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.') {
				return nil, errors.New("invalid_gitlab_project")
			}
		}
	}
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("gitlab_token_required")
	}
	return &gitLabDiscovery{endpoint: strings.TrimRight(endpoint, "/"), project: project, token: token, client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect_not_allowed") }}}, nil
}

// Scope deliberately includes the credential fingerprint, fencing credential
// rotation as well as endpoint/project changes without persisting a credential.
func (g *gitLabDiscovery) Scope() string {
	data, _ := json.Marshal([]string{g.endpoint, g.project, g.token})
	return fmt.Sprintf("%x", sha256.Sum256(data))
}
func (g *gitLabDiscovery) ConfiguredProject() string { return g.project }

// Discover reads only the 100 most recently updated issues in the configured
// project. It never follows provider-controlled pagination links or redirects.
// The caller must retain previously seen tasks absent from this bounded window.
func (g *gitLabDiscovery) Discover(ctx context.Context) ([]obj, error) {
	target := g.endpoint + "/projects/" + url.PathEscape(g.project) + "/issues?state=all&per_page=100&page=1&order_by=updated_at&sort=desc"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, errors.New("gitlab_request_failed")
	}
	req.Header.Set("PRIVATE-TOKEN", g.token)
	req.Header.Set("Accept", "application/json")
	resp, err := g.client.Do(req)
	if err != nil {
		return nil, errors.New("gitlab_unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New("gitlab_unavailable")
	}
	const limit = 2 << 20
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil || len(body) > limit {
		return nil, errors.New("gitlab_invalid_response")
	}
	var issues []obj
	if json.Unmarshal(body, &issues) != nil || issues == nil || len(issues) > 100 {
		return nil, errors.New("gitlab_invalid_response")
	}
	tasks := make([]obj, 0, len(issues))
	seen := map[string]bool{}
	for _, issue := range issues {
		task, err := g.normalize(issue)
		if err != nil {
			return nil, err
		}
		key := task["id"].(string)
		if seen[key] {
			return nil, errors.New("gitlab_invalid_response")
		}
		seen[key] = true
		tasks = append(tasks, task)
	}
	return tasks, nil
}

func boundedText(v any, limit int) string {
	text, _ := v.(string)
	chars := []rune(text)
	if len(chars) > limit {
		return string(chars[:limit])
	}
	return text
}
func (g *gitLabDiscovery) normalize(issue obj) (obj, error) {
	iid, ok := issue["iid"].(float64)
	title, valid := issue["title"].(string)
	status, _ := issue["state"].(string)
	if !ok || iid < 1 || iid > 9007199254740991 || iid != float64(int64(iid)) || !valid || strings.TrimSpace(title) == "" || (status != "opened" && status != "closed") {
		return nil, errors.New("gitlab_invalid_response")
	}
	key := strconv.FormatInt(int64(iid), 10)
	native := obj{"iid": iid, "project_path": g.project}
	for _, k := range []string{"id", "project_id", "references"} {
		if issue[k] != nil {
			native[k] = issue[k]
		}
	}
	labels := []any{}
	if values, ok := issue["labels"].([]any); ok {
		for _, label := range values {
			if text, ok := label.(string); ok && len(labels) < 100 {
				labels = append(labels, boundedText(text, 200))
			}
		}
	}
	sourceURL := ""
	if raw, ok := issue["web_url"].(string); ok {
		if u, err := url.Parse(raw); err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil {
			sourceURL = raw
		}
	}
	source := obj{}
	for _, k := range []string{"iid", "id", "project_id", "title", "description", "state", "updated_at", "labels", "web_url"} {
		source[k] = issue[k]
	}
	encoded, _ := json.Marshal(source)
	stage := "Todo"
	if status == "closed" {
		stage = "Done"
	}
	return obj{"id": key, "external_id": "GL-" + key, "tracker": "gitlab", "native_ref": native, "project": g.project, "title": boundedText(title, 160), "description": boundedText(issue["description"], 4000), "source_digest": fmt.Sprintf("%x", sha256.Sum256(encoded)), "source_state": status, "source_labels": labels, "source_dispatchable": false, "source_updated_at": boundedText(issue["updated_at"], 100), "source_url": sourceURL, "status": status, "stage": stage, "revision": float64(1), "hold": false, "dependencies": []any{}, "release_verified": false, "execution_supported": false, "plan": []any{}, "links": []any{}, "documents": []any{}, "comments": []any{}, "reports": []any{}}, nil
}
