defmodule SymphonyElixirWeb.TasksLive do
  @moduledoc "Multi-task fixture board backed by the same service as the CLI."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixir.Service

  @impl true
  def mount(_, session, socket) do
    token = Application.get_env(:symphony_elixir, :demo_token, "")

    if byte_size(token) >= 32 and session["demo_auth"] == SymphonyElixirWeb.DemoAuth.digest(token) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "demo")
      {:ok, socket |> assign(error: nil, approval: nil, task_id: "fixture-1", detail: false, project: "all") |> refresh()}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_params(params, _, socket) do
    selected = params["task"]
    valid = Enum.any?(socket.assigns.payload["tasks"], &(&1["id"] == selected))

    socket =
      assign(socket,
        task_id: if(valid, do: selected, else: "fixture-1"),
        detail: valid,
        project: params["project"] || "all",
        approval: nil,
        error: if(selected && not valid, do: "Task not found", else: nil)
      )

    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(:demo_updated, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter", %{"project" => project}, socket), do: {:noreply, push_patch(socket, to: "/tasks?" <> URI.encode_query(%{"project" => project}))}

  def handle_event(op, params, socket) do
    params = if op == "check", do: Map.merge(params, %{"step" => parse_step(params["step"]), "completed" => params["completed"] == "true"}), else: params
    revision = if op == "create", do: socket.assigns.payload["board_revision"], else: socket.assigns.payload["task"]["revision"]

    req =
      Map.merge(params, %{
        "op" => op,
        "task_id" => socket.assigns.task_id,
        "run_id" => params["id"],
        "approval" => socket.assigns.approval && socket.assigns.approval["id"],
        "revision" => revision,
        "key" => Base.url_encode64(:crypto.strong_rand_bytes(18)),
        "scope" => "control",
        "actor" => "demo-operator"
      })

    socket =
      case Service.request(req) do
        {:ok, result} when op == "preview" ->
          Process.send_after(self(), :demo_updated, max(result["expires"] * 1000 - System.system_time(:millisecond), 0))
          assign(socket, approval: result, error: nil)

        {:ok, result} when op == "create" ->
          socket |> assign(error: nil) |> push_patch(to: "/tasks?" <> URI.encode_query(%{"task" => result["id"], "project" => result["project"]}))

        {:ok, _} ->
          assign(socket, error: nil)

        {:error, code} ->
          assign(socket, error: code)
      end

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    approval = socket.assigns.approval
    {:ok, payload} = Service.request(%{"op" => "snapshot", "task_id" => socket.assigns.task_id, "approval" => approval && approval["id"]})
    assign(socket, payload: payload, approval: if(payload["approval_valid"], do: approval, else: nil))
  end

  defp parse_step(value) do
    case Integer.parse(to_string(value)) do
      {step, ""} -> step
      _ -> nil
    end
  end

  defp task_runs(payload), do: Enum.filter(payload["runs"], &(&1["task_id"] == payload["task"]["id"]))
  defp task_events(payload), do: Enum.filter(payload["events"], &((&1["task_id"] || "fixture-1") == payload["task"]["id"]))
  defp projects(payload), do: payload["tasks"] |> Enum.map(& &1["project"]) |> Enum.uniq() |> Enum.sort()
  defp column_tasks(payload, project, stage), do: Enum.filter(payload["tasks"], &(&1["stage"] == stage and (project == "all" or &1["project"] == project)))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="work-board">
      <header class="board-header">
        <div><p class="board-eyebrow">SYMPHONY / WORKSPACE</p><h1>Task board</h1><p>From intent to review, with a visible trail.</p></div>
        <span class="fixture-label">● Fixture workspace</span>
      </header>
      <div class="board-notice">Simulated agents · manual dispatch · concurrency one. No live tracker, agent, PR or deployment is connected.</div>
      <p :if={@error} role="alert" class="board-error">{@error}</p>
      <div class="board-toolbar">
        <form phx-change="filter"><label>Project <select name="project" aria-label="Project"><option value="all" selected={@project == "all"}>All projects</option><option :for={project <- projects(@payload)} value={project} selected={@project == project}>{project}</option></select></label></form>
        <span>{length(@payload["tasks"])} tasks · shared API + CLI</span>
        <details class="new-task"><summary>＋ New task</summary><form id="create-task" phx-submit="create">
          <label>Title<input name="title" required maxlength="160" placeholder="What needs to change?" /></label>
          <label>Project<input name="project" required maxlength="80" value={if @project == "all", do: "demo", else: @project} /></label>
          <label>Description<textarea name="description" required maxlength="4000" placeholder="Context and acceptance criteria"></textarea></label>
          <button type="submit">Create task</button>
        </form></details>
      </div>
      <div class="board-columns" aria-label="Task workflow">
        <section :for={stage <- @payload["stages"]} class="board-column" data-stage={stage}>
          <h2><span class="stage-dot"></span>{stage}<small>{length(column_tasks(@payload, @project, stage))}</small></h2>
          <.link :for={task <- column_tasks(@payload, @project, stage)} patch={"/tasks?" <> URI.encode_query(%{"task" => task["id"], "project" => @project})} class="task-card" id={"card-" <> task["id"]}>
            <div class="card-meta"><span>{task["project"]}</span><span>{task["id"]}</span></div>
            <h3>{task["title"]}</h3><p>{task["description"]}</p>
            <div class="card-footer"><span>◇ Simulation</span><span :if={task["hold"]}>On hold</span><span>{Enum.count(task["plan"], & &1["completed"])}/{length(task["plan"])} checks</span></div>
          </.link>
          <p :if={column_tasks(@payload, @project, stage) == []} class="empty-column">Nothing here yet</p>
        </section>
      </div>
      <section :if={@detail} class="task-detail" aria-label="Task detail">
        <header><div><p class="board-eyebrow">{@payload["task"]["project"]} / {@task_id}</p><h2>{@payload["task"]["title"]}</h2></div><.link patch={"/tasks?" <> URI.encode_query(%{"project" => @project})} class="close-detail" aria-label="Close task">✕</.link></header>
        <div class="detail-meta"><span class="stage-tag">{@payload["task"]["stage"]}</span><span>Revision {@payload["task"]["revision"]} · hold: {to_string(@payload["task"]["hold"])}</span><span>Release unverified</span></div>
        <p>{@payload["task"]["description"]}</p>
        <form id="move-task" phx-submit="move" class="inline-form"><label>Board stage<select name="stage"><option :for={stage <- @payload["stages"]} value={stage} selected={@payload["task"]["stage"] == stage}>{stage}</option></select></label><button>Move task</button></form>
        <p class="muted">Moving a card is a manual board update. It does not run an agent, merge a PR or deploy.</p>
        <section class="detail-section"><h3>Plan & checklist <span>Manually maintained</span></h3>
          <div :for={{step, index} <- Enum.with_index(@payload["task"]["plan"])} class="plan-step">
            <button phx-click="check" phx-value-step={index} phx-value-completed={to_string(not step["completed"])} aria-label={"Toggle " <> step["text"]} aria-pressed={to_string(step["completed"])}>{if step["completed"], do: "✓", else: "○"}</button><span>{step["text"]}</span>
          </div>
          <details><summary>Edit plan</summary><form id="edit-plan" phx-submit="plan"><label>One step per line (up to 20)<textarea name="text" required maxlength="4000">{Enum.map_join(@payload["task"]["plan"], "\n", & &1["text"])}</textarea></label><button>Save plan</button></form></details>
        </section>
        <section class="detail-section"><h3>Run controls <span>Fixed simulator</span></h3>
          <div class="run-controls"><button :for={action <- @payload["task"]["allowed_actions"]} phx-click={action}>{action}</button></div>
          <p :if={@approval} class="approval-note">Preview {@approval["id"]}: fixture only; expires after two minutes. No commit, push or deployment authorized.</p>
          <button :if={@approval && task_runs(@payload) == []} phx-click="start">Approve and start simulation</button>
          <article :for={run <- task_runs(@payload)} id={"run-" <> run["id"]} class="run-row">
            <strong>{run["state"]} · attempt {run["attempt"]}</strong><p>{run["id"]} <span :if={run["parent_id"]}>· parent {run["parent_id"]}</span></p>
            <button :if={run["state"] in ["starting", "running"]} phx-click="stop" phx-value-id={run["id"]}>Stop and hold</button>
            <button :if={@approval && length(task_runs(@payload)) < 3 && run["state"] not in ["starting", "running", "stopping"]} phx-click="retry" phx-value-id={run["id"]}>Approve new retry</button>
            <details :if={run["evidence"]}><summary>Simulation evidence</summary><pre>{Jason.encode!(run["evidence"], pretty: true)}</pre></details>
          </article>
          <p :if={task_runs(@payload) == []} class="muted">No runs. Preview the scope before approving a simulation.</p>
        </section>
        <section class="detail-section"><h3>Pull requests & walkthroughs</h3>
          <p :if={@payload["task"]["links"] == []} class="muted">No linked evidence. No PR has been created by this demo.</p>
          <a :for={link <- @payload["task"]["links"]} class="evidence-link" href={link["url"]} target="_blank" rel="noopener noreferrer">↗ {link["title"]}<small>{link["kind"]} · {link["verification"]}</small></a>
          <details><summary>Add an existing evidence link</summary><form id="add-link" phx-submit="link">
            <label>Type<select name="kind"><option value="pull_request">Pull request</option><option value="walkthrough">Walkthrough</option></select></label>
            <label>Title<input name="title" required maxlength="160" /></label><label>HTTPS URL<input type="url" name="url" required maxlength="2000" placeholder="https://…" /></label><button>Add link</button>
          </form></details>
        </section>
        <section class="detail-section"><h3>Activity <span>Durable service events</span></h3><p :if={task_events(@payload) == []} class="muted">No activity yet.</p>
          <details :for={event <- Enum.reverse(task_events(@payload))} id={"event-" <> to_string(event["cursor"])} class="activity-event"><summary><strong>{event["op"]}</strong><time>{event["at"]}</time></summary><pre>{Jason.encode!(event, pretty: true)}</pre></details>
        </section>
      </section>
    </div>
    """
  end
end
