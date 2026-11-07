package main

import (
	"context"
	"time"
)

// Polling only imports source metadata. It does not schedule or execute workers.
func (s *service) pollDiscovery(ctx context.Context) {
	s.refreshDiscovery(ctx)
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.refreshDiscovery(ctx)
		}
	}
}
func (s *service) refreshDiscovery(ctx context.Context) {
	s.mu.Lock()
	g := s.discovery
	closed := s.closed
	if g != nil && !closed && g.Scope() != s.data.DiscoveryScope {
		d := clone(s.data)
		d.DiscoveryError = "runtime_scope_changed"
		if err := s.save(d); err != nil {
			s.fault = err
		} else {
			s.data = d
		}
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	if g == nil || closed {
		return
	}
	tasks, err := g.Discover(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.fault != nil {
		return
	}
	d := clone(s.data)
	if g.Scope() != d.DiscoveryScope {
		d.DiscoveryError = "runtime_scope_changed"
	} else if err != nil {
		d.DiscoveryError = err.Error()
	} else {
		d.DiscoveryError = ""
		for _, incoming := range tasks {
			key := incoming["id"].(string)
			old := d.Tasks[key]
			if old == nil {
				if len(d.Tasks) >= 100 {
					d.DiscoveryError = "task_limit"
					continue
				}
				d.Tasks[key] = incoming
				d.BoardRevision++
				continue
			}
			if old["source_digest"] == incoming["source_digest"] {
				continue
			}
			sourceStatusChanged := old["source_state"] != incoming["source_state"]
			for _, field := range []string{"title", "description", "source_digest", "source_state", "source_labels", "source_dispatchable", "source_updated_at", "source_url", "status", "native_ref"} {
				old[field] = incoming[field]
			}
			// Source status transitions reset the local workflow stage. Metadata-only
			// changes preserve operator edits, even when stage differs from source status.
			if sourceStatusChanged {
				old["stage"] = incoming["stage"]
			}
			old["revision"] = old["revision"].(float64) + 1
		}
	}
	if tasks := boardTasks(d); len(tasks) > 0 {
		d.Task = tasks[0]
	}
	if err := s.save(d); err != nil {
		s.fault = err
		return
	}
	s.data = d
}
