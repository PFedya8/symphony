defmodule SymphonyElixir.RuntimeBoardTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentRuntimeSupervisor, RuntimeBoard, Service}
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SymphonyElixirWeb.Endpoint

  defmodule Provider do
    def fetch_issues_by_states(states), do: fetch(&(&1.state in states))
    def fetch_issues_by_ids(ids), do: fetch(&(&1.id in ids))

    defp fetch(filter) do
      Agent.get(BoardProvider, fn
        :offline -> {:error, :offline}
        issues -> {:ok, Enum.filter(issues, filter)}
      end)
    end
  end

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    token = System.get_env("SYMPHONY_BOARD_TOKEN")
    client = Application.get_env(:symphony_elixir, :gitlab_client_module)
    server = Application.get_env(:symphony_elixir, :demo_server)
    endpoint = Application.get_env(:symphony_elixir, @endpoint)
    System.put_env("SYMPHONY_BOARD_TOKEN", String.duplicate("local-fixture-only-", 3))
    Application.put_env(:symphony_elixir, :gitlab_client_module, Provider)
    Application.put_env(:symphony_elixir, :demo_server, BoardOwner)

    on_exit(fn ->
      restore_env("SYMPHONY_BOARD_TOKEN", token)
      restore_app(:gitlab_client_module, client)
      restore_app(:demo_server, server)
      Application.put_env(:symphony_elixir, @endpoint, endpoint)
    end)

    binary = Path.join(root, "fake-codex")
    marker = Path.join(root, "attempts")

    File.write!(binary, """
    #!/bin/sh
    printf x >> '#{marker}'
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}';;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"local-thread"}}}';;
        4) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"local-turn"}}}'
           sleep 0.3
           printf '%s\\n' '{"method":"turn/completed"}'
           exit 0;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)

    config = %{
      "board" => %{"enabled" => true, "database" => Path.join(root, "runtime.sqlite")},
      "tracker" => %{
        "kind" => "gitlab",
        "active_states" => ["opened"],
        "terminal_states" => ["closed"],
        "provider" => %{"api_url" => "https://gitlab.example/api/v4", "project_path" => "synthetic/one", "api_key" => "synthetic-only"}
      },
      "workspace" => %{"root" => Path.join(root, "workspaces")},
      "agent" => %{"max_concurrent_agents" => 1, "max_turns" => 1},
      "codex" => %{"command" => binary <> " app-server", "turn_timeout_ms" => 5000, "read_timeout_ms" => 1000},
      "polling" => %{"interval_ms" => 100},
      "server" => %{"host" => "127.0.0.1"}
    }

    write_config(config)
    provider_start = {Agent, :start_link, [fn -> [issue("1"), issue("2")] end, [name: BoardProvider]]}
    start_supervised!(%{id: BoardProvider, start: provider_start})
    %{root: root, config: config, marker: marker}
  end

  defp restore_app(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp issue(id),
    do: %Issue{
      id: id,
      identifier: "GL-#{id}",
      title: "Synthetic task #{id}",
      description: "Local provider only",
      state: "opened",
      dispatchable: true,
      native_ref: %{"iid" => String.to_integer(id), "project_path" => "synthetic/one"}
    }

  defp write_config(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic local test only.\n")
    :ok = WorkflowStore.force_reload()
  end

  defp start_runtime do
    opts = [name: BoardRuntime, orchestrator_name: BoardOwner, task_supervisor_name: BoardWorkers]
    start_supervised!({AgentRuntimeSupervisor, opts})
    eventually(fn -> length(snapshot()["tasks"]) == 2 end)
  end

  defp request(req), do: Service.request(req, BoardOwner)

  defp snapshot(id \\ "1") do
    {:ok, payload} = request(%{"op" => "snapshot", "task_id" => id})
    payload
  end

  defp command(op, attrs \\ %{}) do
    req = %{"op" => op, "task_id" => "1", "scope" => "control", "actor" => "board-operator", "revision" => snapshot()["task"]["revision"], "key" => "test-#{System.unique_integer([:positive])}"}
    request(Map.merge(req, attrs))
  end

  defp eventually(fun, tries \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, tries - 1)
        )
  end

  test "polls real adapter automatically but requires one fresh approval for each actual worker", %{marker: marker} do
    start_runtime()
    assert snapshot()["mode"] == "gitlab_runtime"
    refute File.exists?(marker)
    assert {:error, "approval_required"} = command("start")
    assert {:ok, approval} = command("preview")
    assert approval["scope"] =~ "real Codex"
    {:ok, run} = command("start", %{"approval" => approval["id"], "key" => "real-attempt"})
    refute run["simulated"]
    eventually(fn -> Enum.any?(snapshot()["runs"], &(&1["state"] == "succeeded")) end)
    assert File.read!(marker) == "x"
    Agent.update(BoardProvider, fn _ -> :offline end)
    assert {:ok, ^run} = command("start", %{"approval" => approval["id"], "key" => "real-attempt", "revision" => 1})
    assert {:error, "idempotency_conflict"} = command("start", %{"approval" => "other", "key" => "real-attempt", "revision" => 1})
    Agent.update(BoardProvider, fn _ -> [issue("1"), issue("2")] end)
    assert snapshot()["task"]["stage"] == "Human Review"
    assert :sys.get_state(BoardOwner).retry_attempts == %{}
    send(BoardOwner, :tick)
    _ = snapshot()
    assert File.read!(marker) == "x"
    assert {:ok, _} = command("comment", %{"text" => "Reviewed actual observed exit"})
    assert {:ok, _} = command("capabilities")
    assert {:error, "runtime_unsupported_command"} = command("create")
    assert {:error, "runtime_unsupported_command"} = command("runtime-start")
    :ok = stop_supervised(AgentRuntimeSupervisor)
    start_runtime()
    assert length(snapshot()["runs"]) == 1
    assert File.read!(marker) == "x"
  end

  test "actual worker and workspace hook cannot inherit operator authorization", %{root: root, config: config} do
    names = ~w(SYMPHONY_DEMO_TOKEN CLI_TOKEN_ALIAS BOARD_TOKEN_ALIAS)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    System.put_env("SYMPHONY_DEMO_TOKEN", String.duplicate("synthetic-demo-only", 3))
    System.put_env("CLI_TOKEN_ALIAS", System.fetch_env!("SYMPHONY_DEMO_TOKEN"))
    System.put_env("BOARD_TOKEN_ALIAS", System.fetch_env!("SYMPHONY_BOARD_TOKEN"))
    probe = ~s(printf '%s\\n' "$SYMPHONY_BOARD_TOKEN" "$SYMPHONY_DEMO_TOKEN" "$CLI_TOKEN_ALIAS" "$BOARD_TOKEN_ALIAS")
    binary = Path.join(root, "fake-codex")
    worker_trace = Path.join(root, "worker-auth")
    hook_trace = Path.join(root, "hook-auth")
    File.write!(binary, String.replace(File.read!(binary), "#!/bin/sh", "#!/bin/sh\n" <> probe <> " > '#{worker_trace}'"))
    write_config(Map.put(config, "hooks", %{"after_create" => probe <> " > '#{hook_trace}'"}))
    start_runtime()
    {:ok, approval} = command("preview")
    assert {:ok, _} = command("start", %{"approval" => approval["id"]})
    eventually(fn -> Enum.any?(snapshot()["runs"], &(&1["state"] == "succeeded")) end)

    for trace <- [worker_trace, hook_trace] do
      assert File.read!(trace) == String.duplicate("\n", 4)

      for inherited <- String.split(File.read!(trace), "\n", trim: false) do
        conn = Plug.Test.conn(:get, "/api/v1/tasks") |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_req_header("authorization", "Bearer " <> inherited)
        denied = SymphonyElixirWeb.DemoAuth.call(conn, [])
        assert denied.status == 401
        refute Map.has_key?(denied.assigns, :demo_actor)
      end
    end

    operator = Plug.Test.conn(:get, "/api/v1/tasks") |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_req_header("authorization", "Bearer " <> System.fetch_env!("SYMPHONY_BOARD_TOKEN"))
    assert SymphonyElixirWeb.DemoAuth.call(operator, []).assigns.demo_actor == "board-operator"
  end

  test "fresh tracker changes invalidate preview and unavailable provider never launches", %{marker: marker} do
    start_runtime()
    assert {:ok, _} = command("hold")
    assert {:error, "held"} = command("preview")
    assert {:ok, _} = command("release-hold")
    {:ok, preview} = command("preview")
    old_revision = snapshot()["task"]["revision"]
    Agent.update(BoardProvider, fn issues -> Enum.map(issues, &%{&1 | title: "Changed source"}) end)
    assert {:error, "stale_revision"} = command("start", %{"approval" => preview["id"], "revision" => old_revision})
    Agent.update(BoardProvider, fn _ -> :offline end)
    assert {:error, "tracker_refresh_failed"} = command("preview")
    refute File.exists?(marker)
  end

  test "stop addresses the actual worker and restart never resumes it", %{marker: marker} do
    start_runtime()
    {:ok, approval} = command("preview")
    {:ok, run} = command("start", %{"approval" => approval["id"]})
    eventually(fn -> File.exists?(marker) end)
    assert {:ok, _} = command("stop", %{"task_id" => nil, "run_id" => run["id"]})
    assert Enum.find(snapshot()["runs"], &(&1["id"] == run["id"]))["state"] == "stopped"
    assert :sys.get_state(BoardOwner).running == %{}
    assert :sys.get_state(BoardOwner).retry_attempts == %{}
    :ok = stop_supervised(AgentRuntimeSupervisor)
    start_runtime()
    assert snapshot()["task"]["hold"]
    assert File.read!(marker) == "x"
  end

  test "stop and shutdown kill external workers and their delayed background children", %{root: root} do
    binary = Path.join(root, "fake-codex")
    late = Path.join(root, "unauthorized-late-write")
    File.write!(binary, String.replace(File.read!(binary), "sleep 0.3", "(sleep 0.7; printf late >> '#{late}') &\n       sleep 5"))
    start_runtime()
    {:ok, preview} = command("preview")
    {:ok, run} = command("start", %{"approval" => preview["id"]})
    eventually(fn -> Enum.any?(snapshot()["runs"], &(&1["observation"]["event"] == "session_started")) end)
    assert {:ok, _} = command("stop", %{"run_id" => run["id"]})
    Process.sleep(850)
    refute File.exists?(late)
    assert :sys.get_state(SymphonyElixir.LocalProcesses).ports == %{}
    assert {:ok, _} = command("release-hold")
    {:ok, preview} = command("preview")
    assert {:ok, _} = command("retry", %{"run_id" => run["id"], "approval" => preview["id"]})
    eventually(fn -> map_size(:sys.get_state(SymphonyElixir.LocalProcesses).ports) == 1 end)
    :ok = stop_supervised(AgentRuntimeSupervisor)
    Process.sleep(850)
    refute File.exists?(late)
    assert :sys.get_state(SymphonyElixir.LocalProcesses).ports == %{}
  end

  test "stop kills an in-flight checkout hook before it can write later", %{root: root, config: config, marker: marker} do
    late = Path.join(root, "late-hook-write")
    hooks = %{"after_create" => "(sleep 0.7; printf late > '#{late}') & sleep 5"}
    write_config(Map.put(config, "hooks", hooks))
    start_runtime()
    {:ok, preview} = command("preview")
    {:ok, run} = command("start", %{"approval" => preview["id"]})
    eventually(fn -> map_size(:sys.get_state(SymphonyElixir.LocalProcesses).ports) == 1 end)
    assert {:ok, _} = command("stop", %{"run_id" => run["id"]})
    Process.sleep(850)
    refute File.exists?(late)
    refute File.exists?(marker)
    assert :sys.get_state(SymphonyElixir.LocalProcesses).ports == %{}
  end

  test "worker process containment stays enabled when configuration disables the board", %{config: config} do
    Process.put(:symphony_managed_processes, true)
    write_config(put_in(config, ["board", "enabled"], false))
    {:ok, workspace} = Workspace.create_for_issue(issue("1"))
    {:ok, session} = AppServer.start_session(workspace)
    assert Map.has_key?(:sys.get_state(SymphonyElixir.LocalProcesses).ports, session.port)
    assert :ok = AppServer.stop_session(session)
    assert :sys.get_state(SymphonyElixir.LocalProcesses).ports == %{}
  end

  test "enabling board by hot reload cannot launch an unapproved source issue", %{config: config, marker: marker} do
    Agent.update(BoardProvider, fn _ -> [] end)
    write_config(put_in(config, ["board", "enabled"], false))
    opts = [name: BoardRuntime, orchestrator_name: BoardOwner, task_supervisor_name: BoardWorkers]
    start_supervised!({AgentRuntimeSupervisor, opts})
    assert :sys.get_state(BoardOwner).board == nil
    write_config(config)
    Agent.update(BoardProvider, fn _ -> [issue("1")] end)
    send(BoardOwner, :tick)
    Process.sleep(200)
    assert :sys.get_state(BoardOwner).running == %{}
    refute File.exists?(marker)
  end

  test "token rotation revokes connected sessions and outstanding approvals" do
    Process.flag(:trap_exit, true)
    start_runtime()
    start_supervised!({HttpServer, port: 0, host: "127.0.0.1"})
    token = System.fetch_env!("SYMPHONY_BOARD_TOKEN")
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, first, _} = live(conn, "/tasks?task=1")
    {:ok, second, _} = live(conn, "/tasks?task=1")
    {:ok, _preview} = command("preview")
    System.put_env("SYMPHONY_BOARD_TOKEN", String.duplicate("rotated-synthetic-only", 3))
    assert {:error, {:redirect, %{to: "/"}}} = render_click(first, "preview", %{"revision" => "1"})
    send(second.pid, :demo_updated)
    assert_redirect(second, "/")
    assert snapshot()["task"]["comments"] == []
    assert :sys.get_state(BoardOwner).board.data["approvals"] == %{}
    assert {:error, "runtime_scope_changed"} = command("preview")
  end

  test "rotated connected session cannot persist a comment" do
    Process.flag(:trap_exit, true)
    start_runtime()
    start_supervised!({HttpServer, port: 0, host: "127.0.0.1"})
    token = System.fetch_env!("SYMPHONY_BOARD_TOKEN")
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, view, _} = live(conn, "/tasks?task=1")
    System.put_env("SYMPHONY_BOARD_TOKEN", String.duplicate("rotated-synthetic-only", 3))
    assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "comment", %{"text" => "must not persist", "revision" => "1"})
    assert snapshot()["task"]["comments"] == []
  end

  test "workflow changes revoke a connected session before mutation", %{config: config} do
    Process.flag(:trap_exit, true)
    start_runtime()
    start_supervised!({HttpServer, port: 0, host: "127.0.0.1"})
    token = System.fetch_env!("SYMPHONY_BOARD_TOKEN")
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, view, _} = live(conn, "/tasks?task=1")
    write_config(put_in(config, ["agent", "max_turns"], 2))
    assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "comment", %{"text" => "must not persist", "revision" => "1"})
    assert snapshot()["task"]["comments"] == []
  end

  test "configuration changes fence dispatch and databases cannot cross projects", %{config: config} do
    start_runtime()
    changed = put_in(config, ["tracker", "provider", "project_path"], "synthetic/two")
    write_config(changed)
    assert {:error, "runtime_scope_changed"} = command("preview")
    assert snapshot()["runtime_error"] == "runtime_scope_changed"
    :ok = stop_supervised(AgentRuntimeSupervisor)
    assert_raise RuntimeError, ~r/scope mismatch/, fn -> RuntimeBoard.open(Config.settings!(), []) end
  end

  test "shared API and LiveView show observed source and real execution consent" do
    start_runtime()
    start_supervised!({HttpServer, port: 0, host: "127.0.0.1"})
    token = System.get_env("SYMPHONY_BOARD_TOKEN")
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, view, _} = live(conn, "/tasks?task=1")
    assert render(view) =~ "GitLab runtime"
    refute has_element?(view, "#create-task")
    view |> element("button[phx-click=preview]") |> render_click()
    assert has_element?(view, "button", "Approve real worker attempt")
    view |> form("#add-comment", %{text: "Shared actual issue"}) |> render_submit()
    assert length(snapshot()["task"]["comments"]) == 1
  end

  test "runtime projection bounds history and reconciles orphaned workers conservatively" do
    board = RuntimeBoard.open(Config.settings!(), [])

    try do
      board = RuntimeBoard.ingest(board, Enum.map(1..100, &issue(to_string(&1))))
      board = RuntimeBoard.ingest(board, [issue("101")])
      assert map_size(board.data["tasks"]) == 100
      refute Map.has_key?(board.data["tasks"], "101")
      assert RuntimeBoard.run_state(board, "missing", "failed") == board
      run = %{"id" => "orphan", "task_id" => "1", "state" => "running"}
      board = put_in(board.data["runs"], [run])
      board = RuntimeBoard.observe(board, %{}, %{})
      assert hd(board.data["runs"])["state"] == "interrupted"
      assert board.data["tasks"]["1"]["stage"] == "Rework"
      assert hd(board.data["events"])["cursor"] == 1
      board = RuntimeBoard.ingest(board, [%{issue("1") | state: "closed", updated_at: DateTime.utc_now()}])
      board = put_in(board.data["runs"], [run])
      board = RuntimeBoard.observe(board, %{}, %{"1" => %{}})
      assert hd(board.data["runs"])["state"] == "blocked"
      assert board.data["tasks"]["1"]["stage"] == "Done"
      refute board.data["tasks"]["1"]["release_verified"]
    after
      Exqlite.Sqlite3.close(board.db)
    end
  end

  test "configuration and authentication fail closed without touching another scope", %{config: config} do
    settings = Config.settings!()
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent-synthetic-path")
    assert_raise RuntimeError, ~r/requires setsid and kill/, fn -> RuntimeBoard.open(settings, []) end
    restore_env("PATH", previous_path)
    assert_raise RuntimeError, ~r/requires GitLab/, fn -> RuntimeBoard.open(%{settings | tracker: %{settings.tracker | kind: "memory"}}, []) end
    assert_raise RuntimeError, ~r/loopback/, fn -> RuntimeBoard.open(%{settings | server: %{settings.server | host: "0.0.0.0"}}, []) end
    assert_raise RuntimeError, ~r/local worker/, fn -> RuntimeBoard.open(%{settings | worker: %{settings.worker | ssh_hosts: ["remote"]}}, []) end
    token = System.get_env("SYMPHONY_BOARD_TOKEN")
    System.delete_env("SYMPHONY_BOARD_TOKEN")
    assert_raise RuntimeError, ~r/token/, fn -> RuntimeBoard.open(settings, []) end
    System.put_env("SYMPHONY_BOARD_TOKEN", token)
    env_name = "SYMPHONY_TEST_GITLAB_SCOPE"
    previous = System.get_env(env_name)
    on_exit(fn -> restore_env(env_name, previous) end)
    System.put_env(env_name, "synthetic/one")
    write_config(put_in(config, ["tracker", "provider", "project_path"], "$" <> env_name))
    assert Tracker.bind_agent_tools().board_policy == {:gitlab_read_only, "synthetic/one"}
    board = RuntimeBoard.open(Config.settings!(), [])

    try do
      assert RuntimeBoard.current?(board)
      System.put_env(env_name, "synthetic/two")
      refute RuntimeBoard.current?(board)
      fallback = System.get_env("GITLAB_PROJECT_PATH")
      on_exit(fn -> restore_env("GITLAB_PROJECT_PATH", fallback) end)
      System.put_env("GITLAB_PROJECT_PATH", "synthetic/fallback")
      fallback_config = update_in(config, ["tracker", "provider"], &Map.delete(&1, "project_path"))
      write_config(fallback_config)
      assert Tracker.bind_agent_tools().board_policy == {:gitlab_read_only, "synthetic/fallback"}
      write_config(put_in(config, ["board", "enabled"], false))
      assert SymphonyElixirWeb.DemoAuth.token() == nil
      File.write!(Workflow.workflow_file_path(), "---\nboard: [invalid]\n---\ninvalid")
      assert {:error, _} = WorkflowStore.force_reload()
      refute RuntimeBoard.current?(board)
      assert SymphonyElixirWeb.DemoAuth.token() == nil
    after
      Exqlite.Sqlite3.close(board.db)
    end
  end

  test "scope drift stops an active worker without dispatching another project", %{root: root, config: config, marker: marker} do
    path = Path.join(root, "fake-codex")
    File.write!(path, String.replace(File.read!(path), "sleep 0.3", "sleep 2"))
    start_runtime()
    {:ok, approval} = command("preview")
    {:ok, _} = command("start", %{"approval" => approval["id"]})
    eventually(fn -> File.exists?(marker) end)
    write_config(put_in(config, ["tracker", "provider", "project_path"], "synthetic/other"))
    send(BoardOwner, :tick)
    eventually(fn -> :sys.get_state(BoardOwner).running == %{} end)
    assert hd(snapshot()["runs"])["state"] == "blocked"
    assert :sys.get_state(BoardOwner).retry_attempts == %{}
    assert File.read!(marker) == "x"
  end

  test "bound GitLab tool cannot mutate or read another project's endpoints" do
    binding = Tracker.bind_agent_tools()

    client = fn method, path, _query, _body, _opts ->
      send(self(), {:read, method, path})
      {:ok, %{status: 200, body: %{"iid" => 1}}}
    end

    assert Tracker.execute_bound_agent_tool(binding, "gitlab_api", %{"method" => "GET", "path" => "/projects/synthetic%2Fone/issues/1"}, gitlab_client: client)["success"]
    assert_receive {:read, "GET", "/projects/synthetic%2Fone/issues/1"}

    for arguments <- [
          %{"method" => "POST", "path" => "/projects/synthetic%2Fone/issues/1/notes"},
          %{"method" => "GET", "path" => "/projects/other%2Fproject/issues"},
          %{"method" => "GET", "path" => "/projects/synthetic%2Fone/../users"},
          %{"method" => "GET", "path" => "/projects/synthetic%2Fone/issues", "body" => %{"state_event" => "close"}},
          %{"method" => 1, "path" => "/user"},
          %{}
        ] do
      refute Tracker.execute_bound_agent_tool(binding, "gitlab_api", arguments, gitlab_client: client)["success"]
    end

    refute Tracker.execute_bound_agent_tool(binding, "other", %{}, gitlab_client: client)["success"]
    refute_receive {:read, _, _}
  end

  test "workspace ownership is exclusive and credential rotation clears outstanding approvals", %{root: root, config: config} do
    board = RuntimeBoard.open(Config.settings!(), [])
    board = RuntimeBoard.ingest(board, [issue("1")])
    {{:ok, _}, board} = RuntimeBoard.command(%{"op" => "preview", "scope" => "control", "key" => "old-approval", "revision" => 1, "task_id" => "1"}, board)
    :ok = Exqlite.Sqlite3.close(board.db)
    other = put_in(config, ["board", "database"], Path.join(root, "other.sqlite"))
    write_config(other)
    assert_raise RuntimeError, ~r/Workspace root belongs/, fn -> RuntimeBoard.open(Config.settings!(), []) end
    write_config(put_in(config, ["tracker", "provider", "api_key"], "rotated-synthetic-only"))
    refute RuntimeBoard.current?(board)
    rotated = RuntimeBoard.open(Config.settings!(), [])
    assert RuntimeBoard.current?(rotated)
    assert rotated.data["approvals"] == %{}
    assert map_size(rotated.data["tasks"]) == 1
    :ok = Exqlite.Sqlite3.close(rotated.db)
  end

  test "nonempty, unreadable or unsafe workspace bindings fail closed", %{root: root, config: config} do
    for {name, prepare, message} <- [
          {"occupied", fn dir -> File.write!(Path.join(dir, "existing"), "unrelated") end, ~r/empty dedicated/},
          {"unreadable", fn dir -> File.mkdir!(Path.join(dir, ".symphony-board-scope")) end, ~r/Cannot verify/}
        ] do
      dir = Path.join(root, name)
      File.mkdir!(dir)
      prepare.(dir)
      candidate = config |> put_in(["workspace", "root"], dir) |> put_in(["board", "database"], Path.join(root, name <> ".sqlite"))
      write_config(candidate)
      assert_raise RuntimeError, message, fn -> RuntimeBoard.open(Config.settings!(), []) end
    end

    candidate = config |> put_in(["workspace", "root"], Path.join(root, "inside")) |> put_in(["board", "database"], Path.join(root, "inside/state.sqlite"))
    write_config(candidate)
    assert_raise RuntimeError, ~r/outside it/, fn -> RuntimeBoard.open(Config.settings!(), []) end
    settings = Config.settings!()
    assert is_binary(RuntimeBoard.scope_fingerprint(%{settings | tracker: %{settings.tracker | provider: %{}}}))
  end

  test "reserved approval cannot dispatch different issue content" do
    board = RuntimeBoard.open(Config.settings!(), [])

    try do
      source = issue("1")
      board = RuntimeBoard.ingest(board, [source])
      req = %{"task_id" => "1", "scope" => "control", "revision" => 1}
      {{:ok, preview}, board} = RuntimeBoard.command(Map.merge(req, %{"op" => "preview", "key" => "p"}), board)
      {{:ok, _}, board} = RuntimeBoard.command(Map.merge(req, %{"op" => "start", "approval" => preview["id"], "key" => "s"}), board)
      assert RuntimeBoard.authorized_issue?(board, source)
      refute RuntimeBoard.authorized_issue?(board, %{source | description: "Changed after approval"})
      refute RuntimeBoard.authorized_issue?(board, %{source | identifier: "GL-other"})
      refute RuntimeBoard.authorized_issue?(board, %{source | labels: ["changed"]})
      assert board.workers == %{}
    after
      Exqlite.Sqlite3.close(board.db)
    end
  end
end
