defmodule SymphonyElixir.Demo do
  @moduledoc "Manual fixture lifecycle, executed only inside the existing orchestrator. No shell or network tools."
  alias SymphonyElixir.Demo.Store
  @active ~w(starting running stopping)
  @stages ["Backlog", "Todo", "In Progress", "Human Review", "Merging", "Done", "Rework", "Canceled", "Duplicate"]

  @spec open(keyword()) :: map()
  def open(opts) do
    {db, data} = Store.open(Application.fetch_env!(:symphony_elixir, :demo_db))

    data = data || %{"tasks" => initial_tasks(), "board_revision" => 1, "runs" => [], "events" => [], "commands" => %{}, "approvals" => %{}}
    data = migrate(data)

    data = Map.update!(data, "runs", &Enum.map(&1, fn run -> recover(run) end))

    :ok = Store.save(db, data)
    %{db: db, data: data, workers: %{}, supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)}
  end

  @spec command(map(), map()) :: {term(), map()}
  def command(req, state) do
    op = req["op"]
    if op in ~w(snapshot capabilities events), do: read(req, state), else: mutate(req, state)
  catch
    {:reject, code} -> {{:error, code}, state}
  end

  defp recover(run) do
    if run["state"] in @active,
      do: Map.merge(run, %{"state" => "interrupted", "exit_reason" => "owner_lost; reconciliation required"}),
      else: run
  end

  defp read(%{"op" => "capabilities"}, state),
    do: {{:ok, %{"simulated" => true, "manual" => true, "resume" => false, "max_agents" => 1, "max_attempts" => 3, "max_tasks" => 100, "stages" => @stages}}, state}

  defp read(%{"op" => "events"} = req, state) do
    cursor = req["cursor"] || 0
    require!(is_integer(cursor) and cursor >= 0, "invalid_cursor")
    events = Enum.filter(state.data["events"], &(&1["cursor"] > cursor)) |> Enum.take(100) |> Enum.map(&public_event/1)
    {{:ok, %{"items" => events, "cursor" => if(events == [], do: cursor, else: List.last(events)["cursor"])}}, state}
  end

  defp read(req, state) do
    task = task!(state.data, req["task_id"] || "fixture-1")
    actions = if task["hold"], do: ["release-hold"], else: ["preview", "hold"]
    approval = state.data["approvals"][req["approval"]]
    valid = valid_approval?(approval, task)

    {{:ok,
      %{
        "task" => Map.put(task, "allowed_actions", actions),
        "tasks" => state.data["tasks"] |> Map.values() |> Enum.sort_by(& &1["id"]),
        "stages" => @stages,
        "board_revision" => state.data["board_revision"],
        "runs" => Enum.map(state.data["runs"], &Map.delete(&1, "approval")),
        "events" => Enum.map(state.data["events"], &public_event/1),
        "approval_valid" => valid
      }}, state}
  end

  # Shared history must not disclose the private capability returned to the preview caller.
  defp public_event(%{"op" => "preview"} = event), do: update_in(event["result"], &Map.delete(&1, "id"))
  defp public_event(event), do: update_in(event["result"], &Map.delete(&1, "approval"))

  defp mutate(req, state) do
    require!(req["scope"] == "control", "forbidden")
    require!(req["op"] != "resume", "resume_not_supported")
    key = req["key"]
    require!(is_binary(key) and byte_size(key) in 1..100, "idempotency_key_required")
    fingerprint = :crypto.hash(:sha256, Jason.encode!(Map.drop(req, ["key"]))) |> Base.encode16()

    case state.data["commands"][key] do
      %{"fingerprint" => ^fingerprint, "result" => result} -> {{:ok, result}, state}
      nil -> execute(req, fingerprint, state)
      _ -> throw({:reject, "idempotency_conflict"})
    end
  end

  defp execute(req, fingerprint, state) do
    task_id = request_task_id(req, state.data)
    task = task!(state.data, task_id)
    revision = if req["op"] == "create", do: state.data["board_revision"], else: task["revision"]
    require!(req["revision"] == revision, "stale_revision")
    require!(map_size(state.data["commands"]) < 1000, "demo_history_full")
    {result, data, effect} = transition(req, Map.put(state.data, "task", task))
    data = put_in(data["commands"][req["key"]], %{"fingerprint" => fingerprint, "result" => result})
    before_revision = if req["op"] == "create", do: nil, else: task["revision"]
    data = audit(data, req["op"], req["actor"] || "operator", before_revision, result)
    data = unscoped(data)
    :ok = Store.save(state.db, data)
    state = %{state | data: data} |> effect(effect)
    publish()
    {{:ok, result}, state}
  end

  defp transition(%{"op" => "preview"}, data) do
    eligible!(data)
    approval = %{"id" => id(), "task_id" => data["task"]["id"], "revision" => data["task"]["revision"], "expires" => System.system_time(:second) + 120, "scope" => "fixture-only; no external actions"}
    approvals = Map.reject(data["approvals"], fn {_, value} -> value["task_id"] == data["task"]["id"] end)
    {approval, put_in(data["approvals"], Map.put(approvals, approval["id"], approval)), nil}
  end

  defp transition(%{"op" => op} = req, data) when op in ["start", "retry"] do
    eligible!(data)
    approval = data["approvals"][req["approval"]]

    require!(valid_approval?(approval, data["task"]), "approval_required")

    parent = if op == "retry", do: Enum.find(data["runs"], &(&1["id"] == req["run_id"])), else: nil
    require!(op != "retry" or (parent != nil and parent["task_id"] == data["task"]["id"] and parent["state"] not in @active), "invalid_retry")
    runs = Enum.filter(data["runs"], &(&1["task_id"] == data["task"]["id"]))
    require!(runs == [] or op == "retry", "explicit_retry_required")
    require!(length(runs) < 3, "budget_exhausted")

    run = %{
      "id" => id(),
      "task_id" => data["task"]["id"],
      "attempt" => length(runs) + 1,
      "parent_id" => parent && parent["id"],
      "state" => "starting",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "simulated" => true,
      "evidence" => nil,
      "approval" => approval["id"]
    }

    data = data |> Map.put("runs", data["runs"] ++ [run]) |> put_in(["task", "stage"], "In Progress") |> bump()
    {run, data, {:start, run["id"]}}
  end

  defp transition(%{"op" => op}, data) when op in ["hold", "release-hold"] do
    data = data |> put_in(["task", "hold"], op == "hold") |> bump()
    {data["task"], data, nil}
  end

  defp transition(%{"op" => "stop", "run_id" => id}, data) do
    run = Enum.find(data["runs"], &(&1["id"] == id))
    require!(run != nil and run["task_id"] == data["task"]["id"] and run["state"] in @active, "invalid_transition")
    data = data |> update_run(id, %{"state" => "stopping"}) |> put_in(["task", "hold"], true) |> bump()
    {%{"id" => id, "state" => "stopping"}, data, {:stop, id}}
  end

  defp transition(%{"op" => "create"} = req, data) do
    require!(map_size(data["tasks"]) < 100, "task_limit")
    title = text!(req["title"], 160)
    project = text!(req["project"], 80)
    description = text!(req["description"] || "Manually created fixture task. No real agent is connected.", 4000)
    task = fixture("task-" <> id(), title, project, "Backlog") |> Map.put("description", description)
    data = data |> Map.put("task", task) |> Map.update!("board_revision", &(&1 + 1))
    {task, data, nil}
  end

  defp transition(%{"op" => "move", "stage" => stage}, data) do
    require!(stage in @stages, "invalid_stage")
    require!(not Enum.any?(data["runs"], &(&1["task_id"] == data["task"]["id"] and &1["state"] in @active)), "run_active")
    data = data |> put_in(["task", "stage"], stage) |> bump()
    {data["task"], data, nil}
  end

  defp transition(%{"op" => "plan", "text" => text}, data) do
    steps = text!(text, 4000) |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    require!(length(steps) in 1..20 and Enum.all?(steps, &(byte_size(&1) <= 160)), "invalid_plan")
    plan = Enum.map(steps, &%{"text" => &1, "completed" => false})
    data = data |> put_in(["task", "plan"], plan) |> bump()
    {data["task"], data, nil}
  end

  defp transition(%{"op" => "check", "step" => step, "completed" => completed}, data) do
    plan = data["task"]["plan"]
    require!(is_integer(step) and step >= 0 and step < length(plan) and is_boolean(completed), "invalid_step")
    plan = List.update_at(plan, step, &Map.put(&1, "completed", completed))
    data = data |> put_in(["task", "plan"], plan) |> bump()
    {data["task"], data, nil}
  end

  defp transition(%{"op" => "link"} = req, data) do
    require!(req["kind"] in ["pull_request", "walkthrough"], "invalid_link_kind")
    url = text!(req["url"], 2000)
    uri = URI.parse(url)
    require!(uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and uri.userinfo == nil, "invalid_url")
    require!(length(data["task"]["links"]) < 10, "link_limit")
    link = %{"kind" => req["kind"], "url" => url, "title" => text!(req["title"], 160), "verification" => "user supplied; not verified"}
    data = data |> update_in(["task", "links"], &(&1 ++ [link])) |> bump()
    {link, data, nil}
  end

  defp transition(%{"op" => "sync"}, data), do: {%{"simulated" => true, "dispatched" => false}, data, nil}
  defp transition(_, _), do: throw({:reject, "unsupported_command"})

  defp eligible!(data) do
    require!(not data["task"]["hold"], "held")
    require!(data["task"]["status"] == "opened" and data["task"]["stage"] not in ["Done", "Canceled", "Duplicate"], "task_ineligible")
    require!(data["task"]["dependencies"] == [], "dependencies_blocked")
    require!(not Enum.any?(data["runs"], &(&1["state"] in @active)), "capacity")
  end

  defp bump(data), do: update_in(data["task"]["revision"], &(&1 + 1))
  defp update_run(data, id, attrs), do: Map.update!(data, "runs", &Enum.map(&1, fn run -> if run["id"] == id, do: Map.merge(run, attrs), else: run end))

  defp effect(state, nil), do: state

  defp effect(state, {:start, id}) do
    owner = self()

    {:ok, pid} =
      Task.Supervisor.start_child(state.supervisor, fn ->
        send(owner, {:demo_log, id})

        Process.sleep(3_000)
      end)

    ref = Process.monitor(pid)
    %{state | workers: Map.put(state.workers, ref, {id, pid})}
  end

  defp effect(state, {:stop, id}) do
    Enum.each(state.workers, fn {_ref, {run_id, pid}} -> if run_id == id, do: Process.exit(pid, :kill) end)
    state
  end

  @spec event(term(), map()) :: map()
  def event({:demo_log, id}, state) do
    persist(state, state.data |> scope_run(id) |> mark_running(id) |> audit("simulated_worker_started", "simulator", nil, %{"id" => id}))
  end

  def event({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        state

      {{id, _}, workers} ->
        run = Enum.find(state.data["runs"], &(&1["id"] == id))

        status =
          cond do
            run["state"] == "stopping" -> "stopped"
            reason == :normal -> "succeeded"
            true -> "failed"
          end

        evidence =
          if status == "succeeded",
            do: %{"simulated" => true, "changed_files" => [], "commit_sha" => nil, "environment" => "fixture", "checks" => ["simulated completion"], "risks" => ["No real code or deployment verified"]},
            else: nil

        data = state.data |> scope_run(id) |> update_run(id, %{"state" => status, "evidence" => evidence})
        data = if status == "succeeded", do: data |> put_in(["task", "stage"], "Human Review") |> bump(), else: data
        data = data |> audit(status, "simulator", nil, %{"id" => id})
        persist(%{state | workers: workers}, data)
    end
  end

  def event(_, state), do: state

  defp mark_running(data, id) do
    run = Enum.find(data["runs"], &(&1["id"] == id))
    if run && run["state"] == "starting", do: update_run(data, id, %{"state" => "running"}), else: data
  end

  defp persist(state, data) do
    data = unscoped(data)
    :ok = Store.save(state.db, data)
    publish()
    %{state | data: data}
  end

  defp audit(data, op, actor, before_revision, result) do
    cursor =
      case List.last(data["events"]) do
        nil -> 1
        e -> e["cursor"] + 1
      end

    event = %{
      "cursor" => cursor,
      "task_id" => data["task"]["id"],
      "op" => op,
      "actor" => actor,
      "before_revision" => before_revision,
      "after_revision" => data["task"]["revision"],
      "result" => result,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    Map.update!(data, "events", &Enum.take(&1 ++ [event], -1000))
  end

  defp initial_tasks do
    [
      fixture("fixture-1", "Simulated timeout change", "demo", "Todo"),
      fixture("fixture-2", "Explore retry observability", "demo", "Backlog"),
      fixture("fixture-3", "Review dashboard accessibility", "demo", "Human Review"),
      fixture("fixture-4", "Prepare release checklist", "demo", "Merging"),
      fixture("fixture-5", "Document local setup", "demo", "Done"),
      fixture("fixture-6", "Sketch mobile navigation", "sandbox", "In Progress")
    ]
    |> Map.new(&{&1["id"], &1})
  end

  defp fixture(id, title, project, stage) do
    %{
      "id" => id,
      "tracker" => "fixture",
      "project" => project,
      "external_id" => id,
      "title" => title,
      "status" => "opened",
      "stage" => stage,
      "revision" => 1,
      "hold" => false,
      "dependencies" => [],
      "release_verified" => false,
      "description" => "Synthetic example for the #{project} project. Board stage is manually managed; no real agent, PR or deployment is implied.",
      "plan" => Enum.map(["Inspect the task and constraints", "Prepare the change and checks", "Review evidence before any release"], &%{"text" => &1, "completed" => false}),
      "links" => []
    }
  end

  defp migrate(%{"task" => task} = data) do
    task = Map.merge(fixture(task["id"], task["title"], task["project"], "Todo"), task)
    data |> Map.delete("task") |> Map.put("tasks", %{task["id"] => task}) |> Map.put("board_revision", 1) |> Map.put("approvals", %{})
  end

  defp migrate(data), do: data
  defp task!(data, id), do: Map.get(data["tasks"], id) || throw({:reject, "not_found"})

  defp request_task_id(req, data) do
    run = Enum.find(data["runs"], &(&1["id"] == req["run_id"]))
    req["task_id"] || (run && run["task_id"]) || "fixture-1"
  end

  defp scope_run(data, id) do
    run = Enum.find(data["runs"], &(&1["id"] == id))
    Map.put(data, "task", task!(data, run["task_id"]))
  end

  defp unscoped(data) do
    data |> put_in(["tasks", data["task"]["id"]], data["task"]) |> Map.delete("task")
  end

  defp valid_approval?(nil, _task), do: false

  defp valid_approval?(approval, task) do
    same_task = approval["task_id"] == task["id"]
    current_revision = approval["revision"] == task["revision"]
    unexpired = approval["expires"] > System.system_time(:second)
    same_task and current_revision and unexpired
  end

  defp text!(value, limit) do
    require!(is_binary(value) and byte_size(value) in 1..limit and String.trim(value) != "", "invalid_text")
    value
  end

  defp publish, do: Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "demo", :demo_updated)
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp require!(true, _), do: :ok
  defp require!(_, code), do: throw({:reject, code})
end
