defmodule SymphonyElixir.RuntimeBoard do
  @moduledoc "Durable GitLab board projection owned exclusively by the existing orchestrator."
  alias SymphonyElixir.{Config, Demo, PathSafety, Workflow}
  alias SymphonyElixir.Demo.Store
  @active ~w(authorized starting running stopping)

  @spec open(map(), keyword()) :: map() | nil
  def open(%{board: %{enabled: false}}, _opts), do: nil

  def open(config, opts) do
    if config.tracker.kind != "gitlab" or config.agent.max_concurrent_agents != 1,
      do: raise("Runtime board requires GitLab and agent.max_concurrent_agents=1")

    if config.worker.ssh_hosts != [], do: raise("Runtime board currently requires local worker execution")
    if byte_size(System.get_env("SYMPHONY_BOARD_TOKEN") || "") < 32, do: raise("Runtime board token must contain at least 32 bytes")
    if config.server.host not in ["127.0.0.1", "localhost", "::1"], do: raise("Runtime board must bind to loopback")
    {path, root} = paths(config)
    binding = scope_fingerprint(config)
    board = Demo.open(Keyword.merge(opts, database: path, tasks: %{}, runtime_scope: binding))

    try do
      bind_workspace!(root, path, binding)
      File.chmod!(path, 0o600)
      Map.put(board, :config_binding, configuration_fingerprint(config))
    rescue
      error ->
        Exqlite.Sqlite3.close(board.db)
        reraise error, __STACKTRACE__
    end
  end

  @spec scope_fingerprint(map()) :: String.t()
  def scope_fingerprint(config) do
    project = resolve(config.tracker.provider["project_path"], System.get_env("GITLAB_PROJECT_PATH"))
    endpoint = resolve(config.tracker.provider["api_url"], System.get_env("GITLAB_API_URL") || "https://gitlab.com/api/v4")
    :crypto.hash(:sha256, :erlang.term_to_binary({project, endpoint, paths(config)})) |> Base.encode16()
  end

  defp resolve("$" <> name, fallback), do: System.get_env(name) || fallback
  defp resolve(nil, fallback), do: fallback
  defp resolve(value, _), do: value

  defp paths(config) do
    base = Path.dirname(Workflow.workflow_file_path())
    {:ok, database} = PathSafety.canonicalize(Path.expand(config.board.database, base))
    {:ok, root} = PathSafety.canonicalize(Path.expand(config.workspace.root, base))
    {database, root}
  end

  defp bind_workspace!(root, database, binding) do
    if root == "/" or database == root or String.starts_with?(database, root <> "/"),
      do: raise("Use a dedicated workspace root and keep the board database outside it")

    File.mkdir_p!(root)
    marker = Path.join(root, ".symphony-board-scope")

    case File.read(marker) do
      {:ok, ^binding} ->
        :ok

      {:ok, _} ->
        raise "Workspace root belongs to another board scope"

      {:error, :enoent} ->
        if File.ls!(root) != [], do: raise("Use an empty dedicated workspace root")
        File.write!(marker, binding, [:exclusive])
        File.chmod!(marker, 0o600)

      {:error, _} ->
        raise "Cannot verify workspace ownership"
    end

    File.chmod!(root, 0o700)
  end

  defp configuration_fingerprint(config) do
    scope = Map.take(Map.from_struct(config), [:tracker, :workspace, :worker, :agent, :codex, :hooks, :board])

    provider_env =
      Enum.map(config.tracker.provider, fn
        {key, "$" <> name} -> {key, System.get_env(name)}
        {key, value} -> {key, value}
      end)
      |> Enum.sort()

    fallback = Enum.map(~w(GITLAB_PROJECT_PATH GITLAB_API_URL GITLAB_PAT), &System.get_env/1)
    :crypto.hash(:sha256, :erlang.term_to_binary({scope, provider_env, fallback, Path.expand(Workflow.workflow_file_path()), Config.workflow_prompt()})) |> Base.encode16()
  end

  @spec current?(map()) :: boolean()
  def current?(board) do
    with :ok <- Config.validate!(), {:ok, config} <- Config.settings() do
      board.config_binding == configuration_fingerprint(config)
    else
      _ -> false
    end
  end

  @spec ingest(map(), list()) :: map()
  def ingest(board, issues) do
    tasks = Enum.reduce(Enum.take(issues, 100), board.data["tasks"], &merge_issue/2)
    save(board, Map.put(board.data, "tasks", tasks))
  end

  defp merge_issue(issue, tasks) do
    if Map.has_key?(tasks, issue.id) or map_size(tasks) < 100 do
      old = tasks[issue.id]
      incoming = task(issue)
      fields = ~w(title description status source_state source_updated_at source_labels source_dispatchable source_digest dependencies native_ref project source_url)
      merged = if old, do: Map.merge(old, Map.take(incoming, fields)), else: incoming
      changed_fields = ~w(title description status source_updated_at source_labels source_dispatchable source_digest)
      changed = old && Map.take(old, changed_fields) != Map.take(merged, changed_fields)
      merged = if changed, do: Map.update!(merged, "revision", &(&1 + 1)), else: merged
      merged = if issue.state == "closed", do: Map.put(merged, "stage", "Done"), else: merged
      Map.put(tasks, issue.id, merged)
    else
      tasks
    end
  end

  defp task(issue) do
    %{
      "id" => issue.id,
      "external_id" => issue.identifier,
      "tracker" => "gitlab",
      "native_ref" => issue.native_ref,
      "project" => (issue.native_ref || %{})["project_path"] || "configured-gitlab-project",
      "title" => String.slice(issue.title || issue.identifier, 0, 160),
      "description" => String.slice(issue.description || "", 0, 4000),
      "source_digest" => issue_digest(issue),
      "source_state" => issue.state,
      "source_labels" => issue.labels,
      "source_dispatchable" => issue.dispatchable,
      "source_updated_at" => if(issue.updated_at, do: DateTime.to_iso8601(issue.updated_at), else: nil),
      "source_url" => issue.url,
      "status" => issue.state,
      "stage" => if(issue.state == "closed", do: "Done", else: "Todo"),
      "revision" => 1,
      "hold" => false,
      "dependencies" => issue.blocked_by,
      "release_verified" => false,
      "plan" => [],
      "links" => [],
      "documents" => [],
      "comments" => [],
      "reports" => []
    }
  end

  @spec command(map(), map()) :: {term(), map()}
  def command(req, board) do
    cond do
      req["op"] == "snapshot" ->
        snapshot(req, board)

      not current?(board) and req["op"] != "stop" ->
        {{:error, "runtime_scope_changed"}, board}

      req["op"] in ~w(create sync runtime-start) ->
        {{:error, "runtime_unsupported_command"}, board}

      req["op"] == "capabilities" ->
        {{:ok, capabilities}, board} = Demo.command(req, board)
        {{:ok, Map.merge(capabilities, %{"mode" => "gitlab_runtime", "simulated" => false, "execution_owner" => "existing_orchestrator"})}, board}

      req["op"] == "preview" ->
        preview(req, board)

      true ->
        Demo.command(runtime_request(req), board)
    end
  end

  defp preview(req, board) do
    case Demo.command(req, board) do
      {{:ok, approval}, board} ->
        config = Config.settings!()
        scope = approval["scope"] <> "; max #{config.agent.max_turns} turns; sandbox #{config.codex.thread_sandbox}; provider tool restricted to project issue/MR reads"
        {{:ok, Map.put(approval, "scope", scope)}, board}

      result ->
        result
    end
  end

  @spec replay(map(), map()) :: {:ok, map()} | {:error, String.t()} | :missing
  def replay(%{"op" => op} = req, board) when op in ~w(start retry stop) do
    req = runtime_request(req)
    fingerprint = :crypto.hash(:sha256, Jason.encode!(Map.drop(req, ["key"]))) |> Base.encode16()

    case board.data["commands"][req["key"]] do
      nil -> :missing
      %{"fingerprint" => ^fingerprint, "result" => result} -> {:ok, result}
      _ -> {:error, "idempotency_conflict"}
    end
  end

  def replay(_, _), do: :missing

  defp runtime_request(req) do
    if req["op"] in ~w(start retry), do: req |> Map.put("runtime_action", req["op"]) |> Map.put("op", "runtime-start"), else: req
  end

  defp snapshot(req, board) do
    task_id = req["task_id"]
    task_id = if Map.has_key?(board.data["tasks"], task_id), do: task_id, else: board.data["tasks"] |> Map.keys() |> Enum.sort() |> List.first()

    if task_id do
      {{:ok, payload}, board} = Demo.command(Map.put(req, "task_id", task_id), board)
      {{:ok, payload |> Map.put("mode", "gitlab_runtime") |> Map.put("runtime_error", if(current?(board), do: nil, else: "runtime_scope_changed"))}, board}
    else
      empty = %{"id" => "", "revision" => 0, "stage" => "Backlog", "plan" => [], "documents" => [], "comments" => [], "reports" => [], "links" => []}
      {{:ok, %{"mode" => "gitlab_runtime", "task" => empty, "tasks" => [], "runs" => [], "events" => [], "stages" => [], "board_revision" => 1, "approval_valid" => false}}, board}
    end
  end

  @spec authorized?(map(), String.t()) :: boolean()
  def authorized?(board, id), do: current?(board) and Enum.any?(board.data["runs"], &(&1["task_id"] == id and &1["state"] == "authorized"))

  @spec authorized_issue?(map() | nil, SymphonyElixir.Tracker.Issue.t()) :: boolean()
  def authorized_issue?(nil, _), do: true

  def authorized_issue?(board, issue) do
    authorized?(board, issue.id) and
      Enum.any?(board.data["runs"], fn run ->
        run["task_id"] == issue.id and run["state"] == "authorized" and run["source_digest"] == issue_digest(issue)
      end)
  end

  defp issue_digest(issue) do
    source = Map.take(Map.from_struct(issue), [:id, :identifier, :native_ref, :title, :description, :state, :labels, :updated_at, :blocked_by, :dispatchable])
    :crypto.hash(:sha256, :erlang.term_to_binary(source)) |> Base.encode16()
  end

  @spec run_state(map(), String.t(), String.t(), map()) :: map()
  def run_state(board, task_id, status, observation \\ %{}) do
    old = Enum.find(board.data["runs"], &(&1["task_id"] == task_id and &1["state"] in @active))

    if old do
      updated = Map.merge(old, %{"state" => status, "observation" => observation})
      runs = Enum.map(board.data["runs"], &replace_run(&1, old["id"], updated))
      data = Map.put(board.data, "runs", runs)
      data = if old["state"] != status, do: record_transition(data, task_id, updated), else: data
      save(board, data)
    else
      board
    end
  end

  defp replace_run(run, id, updated), do: if(run["id"] == id, do: updated, else: run)

  defp record_transition(data, task_id, run) do
    task = data["tasks"][task_id]

    stage =
      cond do
        task["status"] == "closed" -> "Done"
        run["state"] in ~w(starting running) -> "In Progress"
        run["state"] == "succeeded" -> "Human Review"
        run["state"] == "stopped" -> "Todo"
        true -> "Rework"
      end

    task = task |> Map.put("stage", stage) |> Map.update!("revision", &(&1 + 1))

    cursor =
      case List.last(data["events"]) do
        nil -> 1
        last -> last["cursor"] + 1
      end

    event = %{
      "cursor" => cursor,
      "task_id" => task_id,
      "op" => "runtime_" <> run["state"],
      "actor" => "orchestrator",
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "result" => Map.take(run, ~w(id state observation)),
      "before_revision" => task["revision"] - 1,
      "after_revision" => task["revision"]
    }

    data |> put_in(["tasks", task_id], task) |> Map.update!("events", &Enum.take(&1 ++ [event], -1000))
  end

  @spec observe(map() | nil, map(), map()) :: map() | nil
  def observe(nil, _, _), do: nil

  def observe(board, running, blocked) do
    Enum.reduce(board.data["runs"], board, &observe_run(&1, &2, running, blocked))
  end

  defp observe_run(run, board, running, blocked) do
    id = run["task_id"]

    cond do
      Map.has_key?(running, id) ->
        entry = running[id]
        observation = %{"event" => to_string(entry.last_codex_event || "worker_started"), "turn_count" => entry.turn_count}
        run_state(board, id, "running", observation)

      run["state"] in ~w(starting running stopping) ->
        status = if Map.has_key?(blocked, id), do: "blocked", else: "interrupted"
        run_state(board, id, status)

      true ->
        board
    end
  end

  defp save(board, data) do
    if data != board.data do
      :ok = Store.save(board.db, data)
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "demo", :demo_updated)
    end

    %{board | data: data}
  end
end
