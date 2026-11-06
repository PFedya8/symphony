# Integration boundaries and extension plan

Inspected at baseline `c1aa579de8bf726a31cbabbaddfe1cb4fd52e4b0` (main, including
published manual slice `291937e7c26d7c5c89894238ae23cb18b4fe4653`).

## What exists

The Elixir `Tracker` adapter registry supports Asana, GitHub, GitLab, Jira, Linear
and memory. No Google Calendar or Google Tasks adapter, OAuth consent flow, token
refresh store, calendar trigger, or Google-task synchronization was found in the
implementation. The Go service implements only the memory fixture lifecycle;
it has none of those external providers.

GitLab's implementation is in `elixir/lib/symphony_elixir/gitlab/`:

- `adapter.ex` supplies the tracker read callbacks and validates configuration.
- `client.ex` polls project-scoped issues, paginates, normalizes `opened`/`closed`
  states and exposes route-safe `GL-<iid>` identifiers.
- `agent_tool.ex` advertises `gitlab_api` for GET, POST, PUT and DELETE requests.
  The service adds the configured bearer credential on the host. Selected tracker
  settings are bound for each agent session so reload cannot change its provider.
- Provider credential variable names and aliases are filtered out of Codex child
  environments by the tracker/workspace boundary. This does not turn the raw REST
  tool into a read-only tool or enforce a per-project mutation allowlist: it accepts
  relative API paths, so its effective access is bounded by the supplied credential.

Example **Elixir** workflow fragment (not consumed by the Go fixture):

```yaml
tracker:
  kind: gitlab
  active_states: [opened]
  terminal_states: [closed]
  provider:
    project_path: "$GITLAB_PROJECT_PATH"
    api_key: "$GITLAB_PAT"
    api_url: https://gitlab.com/api/v4
workspace:
  root: /separate/workspaces/project-beta
```

Supply only the credential authorized for that project's intended operations.
The code does not request, inspect or enforce GitLab OAuth/PAT scope names. Polling
needs issue-read access; optional mutation tools need the corresponding write
permissions. Exact provider scope selection must be verified with the deployed
GitLab version and organizational policy. No credential or external account was
created or connected during this work; live GitLab was not exercised.

## Practical reuse across projects

For the existing Elixir runtime, run independent instances with separate workflow
files, workspace roots, ports and provider credentials. Use its documented normal
CLI/workflow startup; `demo.exs` deliberately loads its own fixed demo workflow and
is not a real-project launcher. Avoid overlapping roots or a shared demo database.
For the Go fixture, `SYMPHONY_PROJECT` plus separate DB/port/token is implemented and
two-project isolation is tested. It remains a synthetic fixture, not an issue importer.

## Planned optional integrations (not implemented)

Use the existing `Tracker` read callbacks (`fetch_issues_by_states` and
`fetch_issues_by_ids`) for a Google Tasks adapter, with explicit stable IDs, mapping
of list/task completion to canonical states, pagination and reconciliation rules.
Keep optional writes behind provider tools; do not put another scheduler in the UI.
Google Calendar would need an explicit product decision: calendar events are not
issues. A read-only availability/context provider can be separate from issue
eligibility; calendar events must not implicitly authorize agent dispatch.

Any future Google implementation needs a separately approved OAuth connection,
minimum read-only scopes for the selected resource first, secure refresh-token
storage, revocation handling, and project/account binding. Write capabilities need
separate authorization and tests for duplicates, expired credentials, rate limits,
deleted events/tasks and cross-project isolation. No Google scopes are requested
by today's code. The Go service should not acquire provider credentials until a
real tracker/agent architecture is implemented and tested; adding a project label
alone does not make that functionality available.
