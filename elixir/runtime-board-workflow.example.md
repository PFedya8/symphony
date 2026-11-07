---
# Real board execution is currently disabled pending verified OS containment.
# This config enables issue discovery and review, not permission to launch workers.
tracker:
  kind: gitlab
  active_states: [opened]
  terminal_states: [closed]
  provider:
    api_url: $GITLAB_API_URL
    project_path: $GITLAB_PROJECT_PATH
    api_key: $GITLAB_PAT
board:
  enabled: true
  database: .runtime-state/board.sqlite
workspace:
  root: .runtime-workspaces
agent:
  max_concurrent_agents: 1
  max_turns: 1
worker:
  ssh_hosts: []
polling:
  interval_ms: 30000
server:
  host: 127.0.0.1
  port: 4000
codex:
  command: codex app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---
Work on issue {{ issue.identifier }}: {{ issue.title }}.

{{ issue.description }}

Respect the configured workspace and do not publish or merge changes without
separate authorization. Report any required permission or unavailable repository.
This example intentionally supplies no checkout hooks; configure reviewed hooks
for the intended repository before authorizing real work.
