defmodule SymphonyElixir.Demo do
  @moduledoc "Manual fixture lifecycle, executed only inside the existing orchestrator. No shell or network tools."
  alias SymphonyElixir.Demo.Store
  @active ~w(starting running stopping)

  @spec open(keyword()) :: map()
  def open(opts) do
    {db, data} = Store.open(Application.fetch_env!(:symphony_elixir, :demo_db))

    data =
      data ||
        %{
          "task" => %{
            "id" => "fixture-1",
            "tracker" => "fixture",
            "project" => "demo",
            "external_id" => "1",
            "title" => "Simulated timeout change",
            "status" => "opened",
            "revision" => 1,
            "hold" => false,
            "dependencies" => [],
            "release_verified" => false
          },
          "runs" => [],
          "events" => [],
          "commands" => %{},
          "approvals" => %{}
        }

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

  defp read(%{"op" => "capabilities"}, state), do: {{:ok, %{"simulated" => true, "manual" => true, "resume" => false, "max_agents" => 1, "max_attempts" => 3}}, state}

  defp read(%{"op" => "events"} = req, state) do
    cursor = req["cursor"] || 0
    require!(is_integer(cursor) and cursor >= 0, "invalid_cursor")
    events = Enum.filter(state.data["events"], &(&1["cursor"] > cursor)) |> Enum.take(100) |> Enum.map(&public_event/1)
    {{:ok, %{"items" => events, "cursor" => if(events == [], do: cursor, else: List.last(events)["cursor"])}}, state}
  end

  defp read(req, state) do
    task = state.data["task"]
    actions = if task["hold"], do: ["release-hold"], else: ["preview", "hold"]
    approval = state.data["approvals"][req["approval"]]
    valid = approval != nil and approval["revision"] == task["revision"] and approval["expires"] > System.system_time(:second)

    {{:ok,
      %{
        "task" => Map.put(task, "allowed_actions", actions),
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
    task = state.data["task"]
    require!(req["revision"] == task["revision"], "stale_revision")
    require!(req["task_id"] in [nil, task["id"]], "not_found")
    require!(map_size(state.data["commands"]) < 1000, "demo_history_full")
    {result, data, effect} = transition(req, state.data)
    data = put_in(data["commands"][req["key"]], %{"fingerprint" => fingerprint, "result" => result})
    data = audit(data, req["op"], req["actor"] || "operator", task["revision"], result)
    :ok = Store.save(state.db, data)
    state = %{state | data: data} |> effect(effect)
    publish()
    {{:ok, result}, state}
  end

  defp transition(%{"op" => "preview"}, data) do
    eligible!(data)
    approval = %{"id" => id(), "revision" => data["task"]["revision"], "expires" => System.system_time(:second) + 120, "scope" => "fixture-only; no external actions"}
    {approval, put_in(data["approvals"], %{approval["id"] => approval}), nil}
  end

  defp transition(%{"op" => op} = req, data) when op in ["start", "retry"] do
    eligible!(data)
    approval = data["approvals"][req["approval"]]
    require!(approval != nil and approval["revision"] == data["task"]["revision"] and approval["expires"] > System.system_time(:second), "approval_required")
    parent = if op == "retry", do: Enum.find(data["runs"], &(&1["id"] == req["run_id"])), else: nil
    require!(op != "retry" or (parent != nil and parent["state"] not in @active), "invalid_retry")
    require!(data["runs"] == [] or op == "retry", "explicit_retry_required")
    require!(length(data["runs"]) < 3, "budget_exhausted")

    run = %{
      "id" => id(),
      "task_id" => "fixture-1",
      "attempt" => length(data["runs"]) + 1,
      "parent_id" => parent && parent["id"],
      "state" => "starting",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "simulated" => true,
      "evidence" => nil,
      "approval" => approval["id"]
    }

    data = data |> Map.put("runs", data["runs"] ++ [run]) |> Map.put("approvals", %{}) |> bump()
    {run, data, {:start, run["id"]}}
  end

  defp transition(%{"op" => op}, data) when op in ["hold", "release-hold"] do
    data = data |> put_in(["task", "hold"], op == "hold") |> bump()
    {data["task"], data, nil}
  end

  defp transition(%{"op" => "stop", "run_id" => id}, data) do
    run = Enum.find(data["runs"], &(&1["id"] == id))
    require!(run != nil and run["state"] in @active, "invalid_transition")
    data = data |> update_run(id, %{"state" => "stopping"}) |> put_in(["task", "hold"], true) |> bump()
    {%{"id" => id, "state" => "stopping"}, data, {:stop, id}}
  end

  defp transition(%{"op" => "sync"}, data), do: {%{"simulated" => true, "dispatched" => false}, data, nil}
  defp transition(_, _), do: throw({:reject, "unsupported_command"})

  defp eligible!(data) do
    require!(not data["task"]["hold"], "held")
    require!(data["task"]["status"] == "opened", "task_ineligible")
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
    persist(state, state.data |> mark_running(id) |> audit("simulated_worker_started", "simulator", nil, %{"id" => id}))
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

        data = state.data |> update_run(id, %{"state" => status, "evidence" => evidence}) |> audit(status, "simulator", nil, %{"id" => id})
        persist(%{state | workers: workers}, data)
    end
  end

  def event(_, state), do: state

  defp mark_running(data, id) do
    run = Enum.find(data["runs"], &(&1["id"] == id))
    if run && run["state"] == "starting", do: update_run(data, id, %{"state" => "running"}), else: data
  end

  defp persist(state, data) do
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
      "op" => op,
      "actor" => actor,
      "before_revision" => before_revision,
      "after_revision" => data["task"]["revision"],
      "result" => result,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    Map.update!(data, "events", &Enum.take(&1 ++ [event], -1000))
  end

  defp publish, do: Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "demo", :demo_updated)
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp require!(true, _), do: :ok
  defp require!(_, code), do: throw({:reject, code})
end
