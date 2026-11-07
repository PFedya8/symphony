defmodule SymphonyElixirWeb.TasksLive do
  @moduledoc "Multi-task fixture board backed by the same service as the CLI."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias Phoenix.LiveView.JS
  alias SymphonyElixir.Service

  @impl true
  def mount(_, session, socket) do
    token = Application.get_env(:symphony_elixir, :demo_token, "")

    if byte_size(token) >= 32 and session["demo_auth"] == SymphonyElixirWeb.DemoAuth.digest(token) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "demo")
      socket = assign(socket, error: nil, approval: nil, task_id: "fixture-1", detail: false, project: nil, expanded: false)
      {:ok, refresh(socket)}
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
        project: normalize_project(params["project"]),
        approval: nil,
        error: if(selected && not valid, do: "Task not found", else: nil)
      )

    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(:demo_updated, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter", %{"project" => project}, socket), do: {:noreply, push_patch(socket, to: board_path(normalize_project(project)))}

  def handle_event("expand-detail", _, socket), do: {:noreply, assign(socket, expanded: not socket.assigns.expanded)}

  def handle_event("board-move", params, socket) do
    result =
      Service.request(%{
        "op" => "move",
        "task_id" => params["task_id"],
        "stage" => params["stage"],
        "revision" => parse_step(params["revision"]),
        "key" => Base.url_encode64(:crypto.strong_rand_bytes(18)),
        "scope" => "control",
        "actor" => "demo-operator"
      })

    error =
      case result do
        {:ok, _} -> nil
        {:error, code} -> code
      end

    {:noreply, socket |> assign(error: error) |> refresh()}
  end

  def handle_event("begin-draft", %{"form" => form} = params, socket) do
    {:noreply, put_draft(socket, form, Map.take(params, ["revision", "task_id"]))}
  end

  def handle_event("draft", %{"_form" => form} = params, socket), do: {:noreply, put_draft(socket, form, Map.drop(params, ["_target"]))}

  def handle_event("reload-draft", %{"form" => form}, socket) do
    {:noreply, socket |> assign(drafts: Map.delete(socket.assigns.drafts, form), error: nil) |> refresh()}
  end

  def handle_event(op, params, socket) do
    params = if op == "check", do: Map.merge(params, %{"step" => parse_step(params["step"]), "completed" => params["completed"] == "true"}), else: params
    socket = put_draft(socket, op, params)
    revision = parse_step(params["revision"])

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

    result = if params["task_id"] in [nil, socket.assigns.task_id], do: Service.request(req), else: {:error, "stale_selection"}

    socket =
      case result do
        {:ok, result} when op == "preview" ->
          Process.send_after(self(), :demo_updated, max(result["expires"] * 1000 - System.system_time(:millisecond), 0))
          assign(socket, approval: result, error: nil)

        {:ok, result} when op == "create" ->
          socket |> assign(error: nil, drafts: Map.delete(socket.assigns.drafts, op)) |> push_patch(to: board_path(result["project"], result["id"]))

        {:ok, _} ->
          assign(socket, error: nil, drafts: Map.delete(socket.assigns.drafts, op))

        {:error, code} ->
          assign(socket, error: code)
      end

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    approval = socket.assigns.approval
    {:ok, payload} = Service.request(%{"op" => "snapshot", "task_id" => socket.assigns.task_id, "approval" => approval && approval["id"]})
    drafts = draft_forms(payload)
    same_task = socket.assigns[:draft_task_id] == socket.assigns.task_id
    previous = if same_task, do: socket.assigns[:drafts] || %{}, else: %{}
    drafts = Map.merge(drafts, Map.filter(previous, fn {_, draft} -> draft["active"] end))
    approval = if payload["approval_valid"], do: approval, else: nil
    assign(socket, payload: payload, drafts: drafts, draft_task_id: socket.assigns.task_id, approval: approval)
  end

  defp put_draft(socket, form, params) do
    if Map.has_key?(socket.assigns.drafts, form) and params["task_id"] in [nil, socket.assigns.task_id] do
      draft = socket.assigns.drafts[form] |> Map.merge(params) |> Map.put("active", true)
      assign(socket, :drafts, Map.put(socket.assigns.drafts, form, draft))
    else
      socket
    end
  end

  defp draft_forms(payload) do
    task = payload["task"]
    base = %{"task_id" => task["id"], "revision" => task["revision"]}

    %{
      "create" => Map.merge(base, %{"revision" => payload["board_revision"], "title" => "", "description" => ""}),
      "move" => Map.put(base, "stage", task["stage"]),
      "plan" => Map.put(base, "text", Enum.map_join(task["plan"], "\n", & &1["text"])),
      "link" => Map.merge(base, %{"kind" => "pull_request", "title" => "", "url" => ""})
    }
  end

  defp parse_step(value) when is_integer(value), do: value

  defp parse_step(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_step(_), do: nil

  defp normalize_project(project) when project in [nil, ""], do: nil
  defp normalize_project(project), do: project
  defp board_path(project, task \\ nil), do: "/tasks?" <> URI.encode_query(Map.reject(%{"project" => project, "task" => task}, fn {_, value} -> is_nil(value) end))

  defp error_message("stale_revision"), do: "This task changed while you were editing. Your draft is preserved. Reload current data before trying again."
  defp error_message(code), do: "Action could not be completed: #{code}. Review the input and try again."

  defp task_runs(payload), do: Enum.filter(payload["runs"], &(&1["task_id"] == payload["task"]["id"]))
  defp task_events(payload), do: Enum.filter(payload["events"], &((&1["task_id"] || "fixture-1") == payload["task"]["id"]))
  defp projects(payload), do: payload["tasks"] |> Enum.map(& &1["project"]) |> Enum.uniq() |> Enum.sort()
  defp column_tasks(payload, project, stage), do: Enum.filter(payload["tasks"], &(&1["stage"] == stage and (is_nil(project) or &1["project"] == project)))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="work-board">
      <header class="board-header">
        <div><p class="board-eyebrow">SYMPHONY / WORKSPACE</p><h1>Task board</h1><p>From intent to review, with a visible trail.</p></div>
        <span class="fixture-label">● Fixture workspace</span>
      </header>
      <div class="board-notice">Simulated agents · manual dispatch · concurrency one. No live tracker, agent, PR or deployment is connected.</div>
      <p :if={@error && not @detail} role="alert" aria-live="assertive" data-error={@error} class="board-error">{error_message(@error)}</p>
      <div class="board-toolbar">
        <form phx-change="filter"><label>Project <select name="project" aria-label="Project"><option value="" selected={is_nil(@project)}>All projects</option><option :for={project <- projects(@payload)} value={project} selected={@project == project}>{project}</option></select></label></form>
        <span>{length(@payload["tasks"])} tasks · shared API + CLI</span>
        <details id="new-task-panel" class="new-task" phx-mounted={JS.ignore_attributes("open")}><summary>＋ New task</summary><form id="create-task" phx-submit="create" phx-change="draft"><input type="hidden" name="_form" value="create" /><input type="hidden" name="revision" value={@drafts["create"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
          <label>Title<input phx-focus="begin-draft" phx-value-form="create" phx-value-revision={@drafts["create"]["revision"]} phx-value-task_id={@task_id} name="title" value={@drafts["create"]["title"]} required maxlength="160" placeholder="What needs to change?" /></label>
          <label>Project<input phx-focus="begin-draft" phx-value-form="create" phx-value-revision={@drafts["create"]["revision"]} phx-value-task_id={@task_id} name="project" required maxlength="80" value={@drafts["create"]["project"] || @project || "demo"} /></label>
          <label>Description<textarea phx-focus="begin-draft" phx-value-form="create" phx-value-revision={@drafts["create"]["revision"]} phx-value-task_id={@task_id} name="description" required maxlength="4000" placeholder="Context and acceptance criteria">{@drafts["create"]["description"]}</textarea></label>
          <button type="submit">Create task</button>
        <button :if={@drafts["create"]["active"]} type="button" phx-click="reload-draft" phx-value-form="create">Reload current data (discard draft)</button></form></details>
      </div>
      <div id="task-workflow" class="board-columns" aria-label="Task workflow" phx-hook="TaskBoard">
        <section :for={stage <- @payload["stages"]} class="board-column" data-stage={stage}>
          <h2><span class="stage-dot"></span>{stage}<small>{length(column_tasks(@payload, @project, stage))}</small></h2>
          <.link :for={task <- column_tasks(@payload, @project, stage)} patch={board_path(@project, task["id"])} class="task-card" draggable="true" data-task-id={task["id"]} data-revision={task["revision"]} id={"card-" <> task["id"]}>
            <div class="card-meta"><span>{task["project"]}</span><span>{task["id"]}</span></div>
            <h3>{task["title"]}</h3><p>{task["description"]}</p>
            <div class="card-footer"><span>◇ Simulation</span><span :if={task["hold"]}>On hold</span><span>{Enum.count(task["plan"], & &1["completed"])}/{length(task["plan"])} checks</span></div>
          </.link>
          <p :if={column_tasks(@payload, @project, stage) == []} class="empty-column">Nothing here yet</p>
        </section>
      </div>
      <section :if={@detail} class={["task-detail", @expanded && "full-page"]} aria-label="Task detail">
        <header><div><p class="board-eyebrow">{@payload["task"]["project"]} / {@task_id}</p><h2>{@payload["task"]["title"]}</h2></div><.link patch={board_path(@project)} class="close-detail" aria-label="Close task">✕</.link></header>
        <p :if={@error} role="alert" aria-live="assertive" data-error={@error} class="board-error">{error_message(@error)}</p>
        <button type="button" phx-click="expand-detail" aria-expanded={to_string(@expanded)}>{if @expanded, do: "Use side panel", else: "Expand task"}</button>
        <div class="detail-meta"><span class="stage-tag">{@payload["task"]["stage"]}</span><span>Revision {@payload["task"]["revision"]} · hold: {to_string(@payload["task"]["hold"])}</span><span>Release unverified</span></div>
        <p>{@payload["task"]["description"]}</p>
        <form id="move-task" phx-submit="move" phx-change="draft" class="inline-form"><input type="hidden" name="_form" value="move" /><input type="hidden" name="revision" value={@drafts["move"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} /><label>Board stage<select phx-focus="begin-draft" phx-value-form="move" phx-value-revision={@drafts["move"]["revision"]} phx-value-task_id={@task_id} name="stage"><option :for={stage <- @payload["stages"]} value={stage} selected={@drafts["move"]["stage"] == stage}>{stage}</option></select></label><button>Move task</button><button :if={@drafts["move"]["active"]} type="button" phx-click="reload-draft" phx-value-form="move">Reload current data (discard draft)</button></form>
        <p class="muted">Moving a card is a manual board update. It does not run an agent, merge a PR or deploy.</p>
        <section class="detail-section"><h3>Plan & checklist <span>Manually maintained</span></h3>
          <div :for={{step, index} <- Enum.with_index(@payload["task"]["plan"])} class="plan-step">
            <button phx-click="check" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-step={index} phx-value-completed={to_string(not step["completed"])} aria-label={"Toggle " <> step["text"]} aria-pressed={to_string(step["completed"])}>{if step["completed"], do: "✓", else: "○"}</button><span>{step["text"]}</span>
          </div>
          <details id="plan-panel" phx-mounted={JS.ignore_attributes("open")}><summary>Edit plan</summary><form id="edit-plan" phx-submit="plan" phx-change="draft"><input type="hidden" name="_form" value="plan" /><input type="hidden" name="revision" value={@drafts["plan"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} /><label>One step per line (up to 20)<textarea phx-focus="begin-draft" phx-value-form="plan" phx-value-revision={@drafts["plan"]["revision"]} phx-value-task_id={@task_id} name="text" required maxlength="4000">{@drafts["plan"]["text"]}</textarea></label><button>Save plan</button><button :if={@drafts["plan"]["active"]} type="button" phx-click="reload-draft" phx-value-form="plan">Reload current data (discard draft)</button></form></details>
        </section>
        <section class="detail-section"><h3>Run controls <span>Fixed simulator</span></h3>
          <div class="run-controls"><button :for={action <- @payload["task"]["allowed_actions"]} phx-click={action} phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id}>{action}</button></div>
          <p :if={@approval} class="approval-note">Preview {@approval["id"]}: fixture only; expires after two minutes. No commit, push or deployment authorized.</p>
          <button :if={@approval && task_runs(@payload) == []} phx-click="start" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id}>Approve and start simulation</button>
          <article :for={run <- task_runs(@payload)} id={"run-" <> run["id"]} class="run-row">
            <strong>{run["state"]} · attempt {run["attempt"]}</strong><p>{run["id"]} <span :if={run["parent_id"]}>· parent {run["parent_id"]}</span></p>
            <button :if={run["state"] in ["starting", "running"]} phx-click="stop" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-id={run["id"]}>Stop and hold</button>
            <button :if={@approval && length(task_runs(@payload)) < 3 && run["state"] not in ["starting", "running", "stopping"]} phx-click="retry" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-id={run["id"]}>Approve new retry</button>
            <details :if={run["evidence"]}><summary>Simulation evidence</summary><pre>{Jason.encode!(run["evidence"], pretty: true)}</pre></details>
          </article>
          <p :if={task_runs(@payload) == []} class="muted">No runs. Preview the scope before approving a simulation.</p>
        </section>
        <section class="detail-section"><h3>Pull requests & walkthroughs</h3>
          <p :if={@payload["task"]["links"] == []} class="muted">No linked evidence. No PR has been created by this demo.</p>
          <a :for={link <- @payload["task"]["links"]} class="evidence-link" href={link["url"]} target="_blank" rel="noopener noreferrer">↗ {link["title"]}<small>{link["kind"]} · {link["verification"]}</small></a>
          <details id="link-panel" phx-mounted={JS.ignore_attributes("open")}><summary>Add an existing evidence link</summary><form id="add-link" phx-submit="link" phx-change="draft"><input type="hidden" name="_form" value="link" /><input type="hidden" name="revision" value={@drafts["link"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
            <label>Type<select phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} name="kind"><option value="pull_request" selected={@drafts["link"]["kind"] == "pull_request"}>Pull request</option><option value="walkthrough" selected={@drafts["link"]["kind"] == "walkthrough"}>Walkthrough</option></select></label>
            <label>Title<input phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} name="title" value={@drafts["link"]["title"]} required maxlength="160" /></label><label>HTTPS URL<input phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} type="url" name="url" value={@drafts["link"]["url"]} required maxlength="2000" placeholder="https://…" /></label><button>Add link</button>
          <button :if={@drafts["link"]["active"]} type="button" phx-click="reload-draft" phx-value-form="link">Reload current data (discard draft)</button></form></details>
        </section>
        <section class="detail-section"><h3>Activity <span>Durable service events</span></h3><p :if={task_events(@payload) == []} class="muted">No activity yet.</p>
          <details :for={event <- Enum.reverse(task_events(@payload))} id={"event-" <> to_string(event["cursor"])} class="activity-event"><summary><strong>{event["op"]}</strong><time>{event["at"]}</time></summary><pre>{Jason.encode!(event, pretty: true)}</pre></details>
        </section>
      </section>
    </div>
    """
  end
end
