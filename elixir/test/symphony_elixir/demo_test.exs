defmodule SymphonyElixir.DemoTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Demo.Store
  alias SymphonyElixir.Service
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), "demo-#{Base.url_encode64(:crypto.strong_rand_bytes(12))}.sqlite")
    Application.put_env(:symphony_elixir, :demo, true)
    Application.put_env(:symphony_elixir, :demo_db, path)
    start_runtime()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :demo)
      Application.delete_env(:symphony_elixir, :demo_db)
      File.rm(path)
      File.rm(path <> "-journal")
    end)

    :ok
  end

  defp start_runtime do
    opts = [name: DemoRuntime, orchestrator_name: DemoOwner, task_supervisor_name: DemoWorkers]
    start_supervised!({SymphonyElixir.AgentRuntimeSupervisor, opts})
  end

  defp request(req), do: Service.request(req, DemoOwner)

  defp snapshot do
    {:ok, data} = request(%{"op" => "snapshot"})
    data
  end

  defp command(op, extras \\ %{}) do
    request(Map.merge(%{"op" => op, "scope" => "control", "revision" => snapshot()["task"]["revision"], "key" => "key-#{System.unique_integer([:positive])}"}, extras))
  end

  defp start_run do
    {:ok, preview} = command("preview")
    {:ok, run} = command("start", %{"approval" => preview["id"]})
    run
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(50)
          eventually(fun, attempts - 1)
        )
  end

  test "reads and sync do not dispatch; unsupported resume and forbidden scope reject" do
    assert snapshot()["runs"] == []
    assert {:ok, _} = command("sync")
    assert {:error, "resume_not_supported"} = command("resume")
    assert {:error, "forbidden"} = request(%{"op" => "start"})
    assert snapshot()["runs"] == []
  end

  test "concurrent idempotent starts create one run and one worker" do
    {:ok, preview} = command("preview")
    req = %{"op" => "start", "scope" => "control", "revision" => 1, "key" => "same", "approval" => preview["id"]}
    replies = 1..10 |> Task.async_stream(fn _ -> request(req) end) |> Enum.map(fn {:ok, {:ok, r}} -> r["id"] end)
    assert length(Enum.uniq(replies)) == 1
    assert length(snapshot()["runs"]) == 1
    assert length(Task.Supervisor.children(DemoWorkers)) == 1
    assert {:error, "idempotency_conflict"} = request(Map.put(req, "revision", 2))
  end

  test "stale revisions and invalidated previews fail" do
    {:ok, preview} = command("preview")
    command("hold")
    command("release-hold")
    assert {:error, "approval_required"} = command("start", %{"approval" => preview["id"]})
    assert {:error, "stale_revision"} = command("hold", %{"revision" => 1})
  end

  test "stop confirms worker death, holds dispatch, retry is a distinct run" do
    run = start_run()
    assert {:ok, %{"state" => "stopping"}} = command("stop", %{"run_id" => run["id"]})
    eventually(fn -> hd(snapshot()["runs"])["state"] == "stopped" end)
    assert Task.Supervisor.children(DemoWorkers) == []
    assert {:error, "held"} = command("preview")
    command("release-hold")
    {:ok, preview} = command("preview")
    {:ok, retry} = command("retry", %{"run_id" => run["id"], "approval" => preview["id"]})
    assert retry["id"] != run["id"]
    assert retry["parent_id"] == run["id"]
  end

  test "success is simulated evidence, never task completion or production verification" do
    start_run()
    eventually(fn -> hd(snapshot()["runs"])["state"] == "succeeded" end)
    assert snapshot()["task"]["status"] == "opened"
    refute snapshot()["task"]["release_verified"]
    assert hd(snapshot()["runs"])["evidence"]["commit_sha"] == nil
  end

  test "restart interrupts unknown execution and preserves hold without replay" do
    start_run()
    command("hold")
    :ok = stop_supervised(SymphonyElixir.AgentRuntimeSupervisor)
    start_runtime()
    assert hd(snapshot()["runs"])["state"] == "interrupted"
    assert snapshot()["task"]["hold"]
    assert Task.Supervisor.children(DemoWorkers) == []
    assert {:error, "held"} = command("preview")
  end

  test "owner crash fences worker and recovers without replay" do
    start_run()
    owner = Process.whereis(DemoOwner)
    [worker] = Task.Supervisor.children(DemoWorkers)
    Process.exit(owner, :kill)
    eventually(fn -> Process.whereis(DemoOwner) not in [nil, owner] end)
    refute Process.alive?(worker)
    assert hd(snapshot()["runs"])["state"] == "interrupted"
    assert Task.Supervisor.children(DemoWorkers) == []
  end

  test "bounded retries, event cursors and cross-task requests" do
    assert {:error, "not_found"} = command("hold", %{"task_id" => "../other"})
    assert {:error, "invalid_cursor"} = request(%{"op" => "events", "cursor" => -1})
    first = start_run()

    Enum.reduce(1..3, first, fn n, run ->
      command("stop", %{"run_id" => run["id"]})
      eventually(fn -> List.last(snapshot()["runs"])["state"] == "stopped" end)
      command("release-hold")
      {:ok, preview} = command("preview")
      result = command("retry", %{"run_id" => run["id"], "approval" => preview["id"]})

      if n == 3 do
        assert result == {:error, "budget_exhausted"}
        run
      else
        {:ok, next} = result
        next
      end
    end)

    {:ok, page} = request(%{"op" => "events", "cursor" => 0})
    assert page["items"] != []
    {:ok, empty} = request(%{"op" => "events", "cursor" => page["cursor"]})
    assert empty["items"] == []
  end

  test "process loss is failed; stale notifications do not create work" do
    start_run()
    [worker] = Task.Supervisor.children(DemoWorkers)
    Process.exit(worker, :kill)
    eventually(fn -> hd(snapshot()["runs"])["state"] == "failed" end)
    send(DemoOwner, {:DOWN, make_ref(), :process, self(), :normal})
    send(DemoOwner, :unknown_message)
    assert length(snapshot()["runs"]) == 1
    assert {:error, "unsupported_command"} = command("deploy")
    assert {:error, "unavailable"} = Service.request(%{"op" => "snapshot"}, MissingOwner)
    :ok = stop_supervised(SymphonyElixir.AgentRuntimeSupervisor)
    start_runtime()
    assert hd(snapshot()["runs"])["state"] == "failed"
  end

  test "unknown database schema is rejected without overwriting data" do
    alias Exqlite.Sqlite3, as: SQL
    path = Path.join(System.tmp_dir!(), "schema-#{Base.url_encode64(:crypto.strong_rand_bytes(12))}.sqlite")
    {db, nil} = Store.open(path)
    :ok = SQL.execute(db, "INSERT INTO demo_state VALUES (1, 999, '{}')")
    :ok = SQL.close(db)
    assert_raise RuntimeError, ~r/Unsupported demo database schema/, fn -> Store.open(path) end
    File.rm!(path)
  end

  test "LiveView start and real HTTP CLI share run IDs, holds and auth rules" do
    token = String.duplicate("fixture-test-only-", 3)
    Application.put_env(:symphony_elixir, :demo_token, token)
    Application.put_env(:symphony_elixir, :demo_server, DemoOwner)
    endpoint_config = Application.get_env(:symphony_elixir, @endpoint)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :demo_token)
      Application.delete_env(:symphony_elixir, :demo_server)
      Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
    end)

    start_supervised!({SymphonyElixir.HttpServer, port: 0, host: "127.0.0.1"})
    port = SymphonyElixir.HttpServer.bound_port()
    assert response(get(build_conn(), "/api/v1/control/snapshot"), 401) == "unauthorized"
    basic = "Basic " <> Base.encode64("demo:" <> token)
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", basic)
    assert response(post(conn, "/api/v1/control/commands", %{"op" => "hold"}), 401) == "unauthorized"
    {:ok, view, html} = live(conn, "/tasks?task=fixture-1")
    assert html =~ "Simulated agents"
    assert SymphonyElixirWeb.DemoAuth.init([]) == []
    assert render_click(view, "resume") =~ "resume_not_supported"
    bearer_conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Bearer " <> token)
    assert json_response(get(bearer_conn, "/api/v1/control/capabilities"), 200)["simulated"]
    assert json_response(get(bearer_conn, "/api/v1/control/events?cursor=0"), 200)["items"] == []
    assert json_response(get(bearer_conn, "/api/v1/control/events?cursor=invalid"), 409)["error"]["code"] == "invalid_cursor"

    view |> element("button", "preview") |> render_click()
    view |> element("button", "Approve and start simulation") |> render_click()
    refute has_element?(view, "button", "Approve and start simulation")
    refute render(view) =~ "Preview "
    run_id = hd(snapshot()["runs"])["id"]
    cli = Path.expand("../cli/symphonyctl")
    env = [{"SYMPHONY_URL", "http://127.0.0.1:#{port}"}, {"SYMPHONY_DEMO_TOKEN", token}]
    {output, 0} = System.cmd(cli, ["runs", "list", "--json"], env: env)
    assert hd(Jason.decode!(output))["id"] == run_id
    revision = to_string(snapshot()["task"]["revision"])
    {_output, 0} = System.cmd(cli, ["runs", "stop", run_id, "--revision", revision], env: env)
    eventually(fn -> render(view) =~ "stopped" end)
    assert render(view) =~ "hold: true"
    assert Enum.any?(snapshot()["events"], &(&1["op"] == "stop"))
    refute has_element?(view, "button", "Approve new retry")
    assert has_element?(view, "details summary", "stop")
    view |> element("button", "release-hold") |> render_click()
    view |> element("button", "preview") |> render_click()
    assert has_element?(view, "button", "Approve new retry")
    command("hold")
    eventually(fn -> not has_element?(view, "button", "Approve new retry") end)
    refute render(view) =~ "Preview "

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        task_id: "fixture-1",
        approval: %{"id" => "expired", "revision" => snapshot()["task"]["revision"], "expires" => System.system_time(:second) - 1}
      }
    }

    assert {:noreply, refreshed} = SymphonyElixirWeb.TasksLive.handle_info(:demo_updated, socket)
    assert refreshed.assigns.approval == nil

    view |> element("button", "release-hold") |> render_click()
    view |> element("button", "preview") |> render_click()
    view |> element("button", "Approve new retry") |> render_click()
    eventually(fn -> render(view) =~ "succeeded" end)
    assert has_element?(view, "details summary", "Simulation evidence")
    refute has_element?(view, "button", "Approve new retry")
  end

  test "two clients invalidate replaced previews without disclosing approval credentials" do
    token = String.duplicate("two-client-test-", 3)
    Application.put_env(:symphony_elixir, :demo_token, token)
    Application.put_env(:symphony_elixir, :demo_server, DemoOwner)
    endpoint_config = Application.get_env(:symphony_elixir, @endpoint)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :demo_token)
      Application.delete_env(:symphony_elixir, :demo_server)
      Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
    end)

    start_supervised!({SymphonyElixir.HttpServer, port: 0, host: "127.0.0.1"})
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, first, _} = live(conn, "/tasks?task=fixture-1")
    {:ok, second, _} = live(conn, "/tasks?task=fixture-1")
    first_html = first |> element("button", "preview") |> render_click()
    [_, first_id] = Regex.run(~r/Preview ([^:]+):/, first_html)
    assert has_element?(first, "button", "Approve and start simulation")
    second_html = second |> element("button", "preview") |> render_click()
    [_, second_id] = Regex.run(~r/Preview ([^:]+):/, second_html)
    assert first_id != second_id
    assert {:ok, %{"approval_valid" => false}} = request(%{"op" => "snapshot", "approval" => first_id})
    assert {:ok, %{"approval_valid" => true}} = request(%{"op" => "snapshot", "approval" => second_id})
    assert snapshot()["task"]["revision"] == 1
    eventually(fn -> not has_element?(first, "button", "Approve and start simulation") end)
    assert has_element?(second, "button", "Approve and start simulation")
    refute render(first) =~ second_id
    refute render(second) =~ first_id
    assert {:error, "approval_required"} = command("start", %{"approval" => first_id})
    second |> element("button", "Approve and start simulation") |> render_click()
    assert length(snapshot()["runs"]) == 1
    {:ok, events} = request(%{"op" => "events"})

    for id <- [first_id, second_id] do
      refute Jason.encode!(snapshot()) =~ id
      refute Jason.encode!(events) =~ id
      refute render(first) =~ id
    end
  end

  defp board_command(task_id, op, attrs \\ %{}) do
    {:ok, data} = request(%{"op" => "snapshot", "task_id" => task_id})
    revision = if op == "create", do: data["board_revision"], else: data["task"]["revision"]
    command(op, Map.merge(%{"task_id" => task_id, "revision" => revision}, attrs))
  end

  test "board create, transitions, checklist and evidence survive restart" do
    assert length(snapshot()["tasks"]) == 6
    assert snapshot()["stages"] == ["Backlog", "Todo", "In Progress", "Human Review", "Merging", "Done"]
    {:ok, task} = board_command("fixture-1", "create", %{"title" => "Second project task", "project" => "new-project"})
    id = task["id"]
    assert task["stage"] == "Backlog"
    assert {:ok, %{"stage" => "Todo"}} = board_command(id, "move", %{"stage" => "Todo"})
    assert {:ok, _} = board_command(id, "plan", %{"text" => "Inspect input\nVerify output"})
    assert {:ok, _} = board_command(id, "check", %{"step" => 0, "completed" => true})
    assert {:ok, _} = board_command(id, "link", %{"kind" => "pull_request", "title" => "User supplied review", "url" => "https://example.com/review/1"})
    assert {:ok, _} = board_command(id, "link", %{"kind" => "walkthrough", "title" => "Walkthrough", "url" => "https://example.com/demo"})
    {:ok, before} = request(%{"op" => "snapshot", "task_id" => id})
    assert hd(before["task"]["plan"])["completed"]
    assert length(before["task"]["links"]) == 2
    refute before["task"]["release_verified"]
    created = Enum.find(before["events"], &(&1["task_id"] == id and &1["op"] == "create"))
    assert created["before_revision"] == nil
    assert created["after_revision"] == 1
    :ok = stop_supervised(SymphonyElixir.AgentRuntimeSupervisor)
    start_runtime()
    assert {:ok, ^before} = request(%{"op" => "snapshot", "task_id" => id})
    assert {:ok, _} = board_command(id, "move", %{"stage" => "Done"})
    assert {:error, "task_ineligible"} = board_command(id, "preview")
    assert {:ok, _} = board_command(id, "move", %{"stage" => "Todo"})
  end

  test "approvals, run lineage and budgets are task scoped with global worker capacity" do
    {:ok, first} = board_command("fixture-1", "preview")
    {:ok, second} = board_command("fixture-2", "preview")
    assert {:error, "approval_required"} = board_command("fixture-2", "start", %{"approval" => first["id"]})
    {:ok, run} = board_command("fixture-2", "start", %{"approval" => second["id"]})
    assert run["task_id"] == "fixture-2"
    assert {:error, "capacity"} = board_command("fixture-1", "start", %{"approval" => first["id"]})
    assert {:error, "run_active"} = board_command("fixture-2", "move", %{"stage" => "Done"})
    assert {:error, "invalid_transition"} = board_command("fixture-1", "stop", %{"run_id" => run["id"]})
    eventually(fn -> hd(snapshot()["runs"])["state"] == "succeeded" end)
    {:ok, after_run} = request(%{"op" => "snapshot", "task_id" => "fixture-2"})
    assert after_run["task"]["stage"] == "Human Review"
    assert {:error, "invalid_retry"} = board_command("fixture-1", "retry", %{"run_id" => run["id"], "approval" => first["id"]})
    assert {:ok, %{"attempt" => 1, "task_id" => "fixture-1"}} = board_command("fixture-1", "start", %{"approval" => first["id"]})
    assert length(Task.Supervisor.children(DemoWorkers)) == 1
  end

  test "board rejects invalid input, unsafe URLs and stale writes" do
    assert {:error, "not_found"} = request(%{"op" => "snapshot", "task_id" => "missing"})
    assert {:error, "invalid_text"} = board_command("fixture-1", "create", %{"title" => " ", "project" => "demo"})
    assert {:error, "invalid_plan"} = board_command("fixture-1", "plan", %{"text" => String.duplicate("x", 161)})
    assert {:error, "invalid_stage"} = board_command("fixture-1", "move", %{"stage" => "Deploy"})
    assert {:error, "invalid_step"} = board_command("fixture-1", "check", %{"step" => 99, "completed" => true})
    assert {:error, "invalid_link_kind"} = board_command("fixture-1", "link", %{"kind" => "script"})

    for url <- ["javascript:alert(1)", "http://example.com", "https://user:pass@example.com"] do
      assert {:error, "invalid_url"} = board_command("fixture-1", "link", %{"kind" => "walkthrough", "url" => url, "title" => "Unsafe"})
    end

    assert {:ok, _} = board_command("fixture-1", "move", %{"stage" => "Backlog"})
    assert {:error, "stale_revision"} = command("move", %{"stage" => "Todo", "revision" => 1})
  end

  test "legacy single-task snapshot migrates without losing runs or silently replaying approvals" do
    alias Exqlite.Sqlite3, as: SQL
    path = Path.join(System.tmp_dir!(), "legacy-#{System.unique_integer([:positive])}.sqlite")
    {db, nil} = Store.open(path)
    legacy = %{"task" => snapshot()["task"] |> Map.drop(["stage", "plan", "links", "description"]), "runs" => [], "events" => [], "commands" => %{}, "approvals" => %{"old" => %{"id" => "old"}}}
    :ok = Store.save(db, legacy)
    :ok = SQL.execute(db, "UPDATE demo_state SET version=1")
    :ok = SQL.close(db)
    previous = Application.fetch_env!(:symphony_elixir, :demo_db)
    Application.put_env(:symphony_elixir, :demo_db, path)
    state = SymphonyElixir.Demo.open([])
    assert map_size(state.data["tasks"]) == 1
    assert state.data["tasks"]["fixture-1"]["stage"] == "Todo"
    assert state.data["approvals"] == %{}
    :ok = SQL.close(state.db)
    Application.put_env(:symphony_elixir, :demo_db, previous)
    File.rm!(path)
  end

  test "board and task detail edits share state with the real HTTP CLI" do
    token = String.duplicate("board-browser-test-", 3)
    Application.put_env(:symphony_elixir, :demo_token, token)
    Application.put_env(:symphony_elixir, :demo_server, DemoOwner)
    endpoint_config = Application.get_env(:symphony_elixir, @endpoint)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :demo_token)
      Application.delete_env(:symphony_elixir, :demo_server)
      Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
    end)

    start_supervised!({SymphonyElixir.HttpServer, port: 0, host: "127.0.0.1"})
    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("demo:" <> token))
    {:ok, board, html} = live(conn, "/tasks")
    assert html =~ "Backlog" and html =~ "Merging"
    refute has_element?(board, ".task-detail")
    render_change(board, "filter", %{"project" => "sandbox"})
    assert has_element?(board, "#card-fixture-6")
    refute has_element?(board, "#card-fixture-1")
    board |> form("#create-task", %{title: "Browser-created task", project: "sandbox", description: "Synthetic acceptance test"}) |> render_submit()
    task = Enum.find(snapshot()["tasks"], &(&1["title"] == "Browser-created task"))
    assert has_element?(board, ".task-detail")
    board |> form("#move-task", %{stage: "Todo"}) |> render_submit()
    board |> form("#edit-plan", %{text: "Review constraints\nVerify browser behavior"}) |> render_submit()
    board |> element("button[phx-click=check][phx-value-step='0']") |> render_click()
    assert render_click(board, "check", %{"step" => "bad", "completed" => "true"}) =~ "invalid_step"
    board |> form("#add-link", %{kind: "walkthrough", title: "Demo guide", url: "https://example.com/guide"}) |> render_submit()
    assert has_element?(board, "a[href='https://example.com/guide']")
    cli = Path.expand("../cli/symphonyctl")
    env = [{"SYMPHONY_URL", "http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}"}, {"SYMPHONY_DEMO_TOKEN", token}]
    {output, 0} = System.cmd(cli, ["tasks", "show", task["id"], "--json"], env: env)
    shown = Jason.decode!(output)
    assert shown["stage"] == "Todo"
    assert hd(shown["plan"])["completed"]
    assert length(shown["links"]) == 1
    {_output, 0} = System.cmd(cli, ["tasks", "move", task["id"], "--stage", "Human Review", "--revision", to_string(shown["revision"])], env: env)
    eventually(fn -> has_element?(board, ".stage-tag", "Human Review") end)
    {:ok, invalid, _} = live(conn, "/tasks?task=missing")
    assert render(invalid) =~ "Task not found"
  end

  test "board resource limits reject additional tasks and evidence without overwriting state" do
    for number <- 1..94 do
      assert {:ok, _} = board_command("fixture-1", "create", %{"title" => "Bounded task #{number}", "project" => "limits"})
    end

    assert length(snapshot()["tasks"]) == 100
    assert {:error, "task_limit"} = board_command("fixture-1", "create", %{"title" => "Overflow", "project" => "limits"})

    for number <- 1..10 do
      assert {:ok, _} = board_command("fixture-1", "link", %{"kind" => "walkthrough", "url" => "https://example.com/#{number}", "title" => "Evidence"})
    end

    assert {:error, "link_limit"} = board_command("fixture-1", "link", %{"kind" => "walkthrough", "url" => "https://example.com/overflow", "title" => "Overflow"})
    assert length(snapshot()["task"]["links"]) == 10
    assert {:error, "invalid_plan"} = board_command("fixture-1", "plan", %{"text" => Enum.map_join(1..21, "\n", &"Step #{&1}")})
  end
end
