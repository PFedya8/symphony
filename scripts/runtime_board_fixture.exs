# Local synthetic provider + Codex protocol fixture using the production orchestrator path.
# No real GitLab requests, repository checkout or Codex credentials are used.
defmodule SymphonyRuntimeFixtureProvider do
  alias SymphonyElixir.Tracker.Issue
  def fetch_issues_by_states(states), do: {:ok, Enum.filter(issues(), &(&1.state in states))}
  def fetch_issues_by_ids(ids), do: {:ok, Enum.filter(issues(), &(&1.id in ids))}
  defp issues do
    for id <- ["101", "102"] do
      %Issue{id: id, identifier: "GL-#{id}", title: "Synthetic GitLab task #{id}",
        description: "Local fake provider and fake Codex protocol process. Actual Symphony scheduling and workspace lifecycle; no live external execution.",
        state: "opened", dispatchable: true, native_ref: %{"iid" => String.to_integer(id), "project_path" => "synthetic/runtime-fixture"}}
    end
  end
end

token = System.fetch_env!("SYMPHONY_BOARD_TOKEN")
if byte_size(token) < 32, do: raise("Use a fresh disposable token of at least 32 bytes")
root = Path.join(System.tmp_dir!(), "symphony-runtime-fixture-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}")
File.mkdir_p!(root)
binary = Path.join(root, "fake-codex")
File.write!(binary, """
#!/bin/sh
printf x >> '#{Path.join(root, "attempts")}'
count=0
while IFS= read -r line; do
  count=$((count + 1))
  case "$count" in
    1) printf '%s\\n' '{"id":1,"result":{}}';;
    2) ;;
    3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"synthetic-thread"}}}';;
    4) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"synthetic-turn"}}}'
       sleep 2
       printf '%s\\n' '{"method":"turn/completed"}'
       exit 0;;
  esac
 done
""")
File.chmod!(binary, 0o755)
config = %{
  "board" => %{"enabled" => true, "database" => Path.join(root, "runtime.sqlite")},
  "tracker" => %{"kind" => "gitlab", "active_states" => ["opened"], "terminal_states" => ["closed"],
    "provider" => %{"api_url" => "https://gitlab.invalid/api/v4", "project_path" => "synthetic/runtime-fixture", "api_key" => "synthetic-not-a-credential"}},
  "workspace" => %{"root" => Path.join(root, "workspaces")},
  "agent" => %{"max_concurrent_agents" => 1, "max_turns" => 1},
  "codex" => %{"command" => binary <> " app-server", "read_timeout_ms" => 1000, "turn_timeout_ms" => 10000},
  "polling" => %{"interval_ms" => 500},
  "server" => %{"port" => 4000, "host" => "127.0.0.1"}
}
workflow = Path.join(root, "WORKFLOW.md")
File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic local verification only.\n")
Application.put_env(:symphony_elixir, :workflow_file_path, workflow)
Application.put_env(:symphony_elixir, :gitlab_client_module, SymphonyRuntimeFixtureProvider)
Application.put_env(:symphony_elixir, :demo, false)
{:ok, _} = Application.ensure_all_started(:symphony_elixir)
IO.puts("Synthetic runtime fixture ready on loopback port 4000")
Process.sleep(:infinity)
