defmodule SymphonyElixirWeb.TasksLive do
  @moduledoc "Multi-task fixture board backed by the same service as the CLI."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias Phoenix.LiveView.JS
  alias SymphonyElixir.Demo.Content
  alias SymphonyElixir.Service

  @impl true
  def mount(_, session, socket) do
    token = SymphonyElixirWeb.DemoAuth.token() || ""

    if byte_size(token) >= 32 and session["demo_auth"] == SymphonyElixirWeb.DemoAuth.digest(token) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "demo")
      socket = assign(socket, error: nil, approval: nil, task_id: "fixture-1", detail: false, project: nil)
      socket = assign(socket, expanded: false, embed_url: nil, auth_digest: session["demo_auth"], auth_context: auth_context())

      socket =
        socket
        |> attach_hook(:authorize_events, :handle_event, fn _, _, socket -> authorize(socket) end)
        |> attach_hook(:authorize_updates, :handle_info, fn _, socket -> authorize(socket) end)
        |> attach_hook(:authorize_navigation, :handle_params, fn _, _, socket -> authorize(socket) end)

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
        embed_url: nil,
        error: if(selected && not valid, do: "Task not found", else: nil)
      )

    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info(:demo_updated, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter", %{"project" => project}, socket), do: {:noreply, push_patch(socket, to: board_path(normalize_project(project)))}

  def handle_event("load-walkthrough", %{"url" => url}, socket) do
    link = Enum.find(socket.assigns.payload["task"]["links"], &(&1["url"] == url and &1["kind"] == "walkthrough"))
    embed_url = if link, do: Content.embed(link["url"]), else: nil
    {:noreply, assign(socket, embed_url: embed_url)}
  end

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
        "actor" => SymphonyElixirWeb.DemoAuth.actor()
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
        "actor" => SymphonyElixirWeb.DemoAuth.actor()
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

  defp auth_context do
    if Application.get_env(:symphony_elixir, :demo, false) do
      :fixture
    else
      SymphonyElixir.Config.settings!() |> SymphonyElixir.RuntimeBoard.configuration_fingerprint()
    end
  end

  defp authorize(socket) do
    token = SymphonyElixirWeb.DemoAuth.token() || ""

    if byte_size(token) >= 32 and socket.assigns.auth_digest == SymphonyElixirWeb.DemoAuth.digest(token) and socket.assigns.auth_context == auth_context() do
      {:cont, socket}
    else
      {:halt, socket |> assign(approval: nil, embed_url: nil) |> redirect(to: "/")}
    end
  end

  defp refresh(socket) do
    approval = socket.assigns.approval
    {:ok, payload} = Service.request(%{"op" => "snapshot", "task_id" => socket.assigns.task_id, "approval" => approval && approval["id"]})
    drafts = draft_forms(payload)
    same_task = socket.assigns[:draft_task_id] == socket.assigns.task_id
    previous = if same_task, do: socket.assigns[:drafts] || %{}, else: %{}
    drafts = Map.merge(drafts, Map.filter(previous, fn {_, draft} -> draft["active"] end))
    approval = if payload["approval_valid"], do: approval, else: nil
    socket = assign(socket, runtime: payload["mode"] == "gitlab_runtime")
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
      "worklog" => Map.merge(base, %{"plan_text" => "", "acceptance_text" => "", "validation_text" => ""}),
      "comment" => Map.merge(base, %{"text" => "", "parent_id" => ""}),
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

  defp section_nodes(assigns) do
    ~H"""
    <ul class="authored-nodes"><li :for={node <- @nodes}>{node["text"]}<.section_nodes :if={node["children"] != []} nodes={node["children"]} /></li></ul>
    """
  end

  defp comment_thread(assigns) do
    ~H"""
    <article :for={comment <- Enum.filter(@comments, &(&1["parent_id"] == @parent))} class="thread-comment" id={"comment-" <> comment["id"]}>
      <header><strong>{comment["author"]}</strong><time>{comment["at"]}</time></header><p>{comment["text"]}</p>
      <small>Comment {comment["id"]}</small><.comment_thread comments={@comments} parent={comment["id"]} />
    </article>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="work-board">
      <header class="board-header">
        <div><p class="board-eyebrow">SYMPHONY / WORKSPACE</p><h1>Task board</h1><p>From intent to review, with a visible trail.</p></div>
        <span class="fixture-label">{if @runtime, do: "● GitLab runtime", else: "● Fixture workspace"}</span>
      </header>
      <div class="board-notice">{if @runtime, do: "GitLab issues · existing Symphony orchestrator · one real worker per explicit approval. Board stages do not change GitLab or verify a merge.", else: "Simulated agents · manual dispatch · concurrency one. No live tracker, agent, PR or deployment is connected."}</div>
      <p :if={@payload["runtime_error"]} role="alert" class="board-error">Runtime configuration changed. Dispatch is blocked; stop any active run and restart with the bound configuration.</p>
      <p :if={@error && not @detail} role="alert" aria-live="assertive" data-error={@error} class="board-error">{error_message(@error)}</p>
      <div class="board-toolbar">
        <form phx-change="filter"><label>Project <select name="project" aria-label="Project"><option value="" selected={is_nil(@project)}>All projects</option><option :for={project <- projects(@payload)} value={project} selected={@project == project}>{project}</option></select></label></form>
        <span>{length(@payload["tasks"])} tasks · shared API + CLI</span>
        <details :if={not @runtime} id="new-task-panel" class="new-task" phx-mounted={JS.ignore_attributes("open")}><summary>＋ New task</summary><form id="create-task" phx-submit="create" phx-change="draft"><input type="hidden" name="_form" value="create" /><input type="hidden" name="revision" value={@drafts["create"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
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
            <div class="card-footer"><span>{if @runtime, do: "GitLab issue", else: "◇ Simulation"}</span><span :if={task["hold"]}>On hold</span><span>{Enum.count(task["plan"], & &1["completed"])}/{length(task["plan"])} checks</span></div>
          </.link>
          <p :if={column_tasks(@payload, @project, stage) == []} class="empty-column">Nothing here yet</p>
        </section>
      </div>
      <section :if={@detail} class={["task-detail", @expanded && "full-page"]} aria-label="Task detail">
        <header><div><p class="board-eyebrow">{@payload["task"]["project"]} / {@task_id}</p><h2>{@payload["task"]["title"]}</h2></div><.link patch={board_path(@project)} class="close-detail" aria-label="Close task">✕</.link></header>
        <p :if={@error} role="alert" aria-live="assertive" data-error={@error} class="board-error">{error_message(@error)}</p>
        <button type="button" phx-click="expand-detail" aria-expanded={to_string(@expanded)}>{if @expanded, do: "Use side panel", else: "Expand task"}</button>
        <div class="detail-meta"><span class="stage-tag">{@payload["task"]["stage"]}</span><span>Revision {@payload["task"]["revision"]} · hold: {to_string(@payload["task"]["hold"])}</span><span>Release unverified</span><span :if={@runtime}>GitLab {@payload["task"]["external_id"]} · source: {@payload["task"]["source_state"]}</span></div>
        <p>{@payload["task"]["description"]}</p>
        <form id="move-task" phx-submit="move" phx-change="draft" class="inline-form"><input type="hidden" name="_form" value="move" /><input type="hidden" name="revision" value={@drafts["move"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} /><label>Board stage<select phx-focus="begin-draft" phx-value-form="move" phx-value-revision={@drafts["move"]["revision"]} phx-value-task_id={@task_id} name="stage"><option :for={stage <- @payload["stages"]} value={stage} selected={@drafts["move"]["stage"] == stage}>{stage}</option></select></label><button>Move task</button><button :if={@drafts["move"]["active"]} type="button" phx-click="reload-draft" phx-value-form="move">Reload current data (discard draft)</button></form>
        <p class="muted">Moving a card is a manual board update. It does not run an agent, merge a PR or deploy.</p>
        <section class="detail-section"><h3>Plan & checklist <span>Manually maintained</span></h3>
          <div :for={{step, index} <- Enum.with_index(@payload["task"]["plan"])} class="plan-step">
            <button phx-click="check" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-step={index} phx-value-completed={to_string(not step["completed"])} aria-label={"Toggle " <> step["text"]} aria-pressed={to_string(step["completed"])}>{if step["completed"], do: "✓", else: "○"}</button><span>{step["text"]}</span>
          </div>
          <details id="plan-panel" phx-mounted={JS.ignore_attributes("open")}><summary>Edit plan</summary><form id="edit-plan" phx-submit="plan" phx-change="draft"><input type="hidden" name="_form" value="plan" /><input type="hidden" name="revision" value={@drafts["plan"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} /><label>One step per line (up to 20)<textarea phx-focus="begin-draft" phx-value-form="plan" phx-value-revision={@drafts["plan"]["revision"]} phx-value-task_id={@task_id} name="text" required maxlength="4000">{@drafts["plan"]["text"]}</textarea></label><button>Save plan</button><button :if={@drafts["plan"]["active"]} type="button" phx-click="reload-draft" phx-value-form="plan">Reload current data (discard draft)</button></form></details>
        </section>
        <section class="detail-section"><p :if={@runtime && !@payload["execution_available"]} role="alert">Execution unavailable: verified OS containment is required. Task discovery and review remain available.</p><h3>Run controls <span>{if @runtime, do: "Runtime execution (test build only)", else: "Fixed simulator"}</span></h3>
          <div class="run-controls"><button :for={action <- @payload["task"]["allowed_actions"]} phx-click={action} phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id}>{action}</button></div>
          <p :if={@approval} class="approval-note">Preview {@approval["id"]}: {@approval["scope"]}. Expires after two minutes.</p>
          <button :if={@approval && task_runs(@payload) == []} phx-click="start" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id}>{if @runtime, do: "Approve synthetic runtime attempt", else: "Approve and start simulation"}</button>
          <article :for={run <- task_runs(@payload)} id={"run-" <> run["id"]} class="run-row">
            <strong>{run["state"]} · attempt {run["attempt"]}</strong><p :if={run["observation"]}>Observed: {run["observation"]["event"]} · release remains unverified</p><p>{run["id"]} <span :if={run["parent_id"]}>· parent {run["parent_id"]}</span></p>
            <button :if={run["state"] in ["starting", "running"]} phx-click="stop" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-id={run["id"]}>Stop and hold</button>
            <button :if={@approval && length(task_runs(@payload)) < 3 && run["state"] not in ["starting", "running", "stopping"]} phx-click="retry" phx-value-revision={@payload["task"]["revision"]} phx-value-task_id={@task_id} phx-value-id={run["id"]}>Approve new retry</button>
            <details :if={run["evidence"]}><summary>Simulation evidence</summary><pre>{Jason.encode!(run["evidence"], pretty: true)}</pre></details>
          </article>
          <p :if={task_runs(@payload) == []} class="muted">No runs. Preview and review the scope before approving an attempt.</p>
        </section>
        <section class="detail-section"><h3>Authored plan & validation</h3><p class="muted">Operator authored; plain text. Indent by two spaces for nested steps, up to three levels.</p>
          <div :if={@payload["task"]["documents"] != []} class="authored-document">
            <div :for={section <- List.last(@payload["task"]["documents"])["sections"]}><h4>{section["title"]}</h4><.section_nodes nodes={section["nodes"]} /></div>
          </div>
          <details id="worklog-panel" phx-mounted={JS.ignore_attributes("open")}><summary>Publish authored update</summary>
            <form id="add-worklog" phx-submit="worklog" phx-change="draft">
              <input type="hidden" name="_form" value="worklog" /><input type="hidden" name="revision" value={@drafts["worklog"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
              <label :for={{field, title} <- [{"plan_text", "Plan"}, {"acceptance_text", "Acceptance Criteria"}, {"validation_text", "Validation"}]}>{title}<textarea name={field} required maxlength="4000" phx-focus="begin-draft" phx-value-form="worklog" phx-value-revision={@drafts["worklog"]["revision"]} phx-value-task_id={@task_id}>{@drafts["worklog"][field]}</textarea></label>
              <button>Publish update</button><button :if={@drafts["worklog"]["active"]} type="button" phx-click="reload-draft" phx-value-form="worklog">Reload current data (discard draft)</button>
            </form>
          </details>
        </section>
        <section class="detail-section"><h3>Discussion</h3><p class="muted">Shared operator identity; replies are preserved with their parent.</p>
          <.comment_thread comments={@payload["task"]["comments"]} parent={nil} />
          <form id="add-comment" phx-submit="comment" phx-change="draft">
            <input type="hidden" name="_form" value="comment" /><input type="hidden" name="revision" value={@drafts["comment"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
            <label>Reply to<select name="parent_id" phx-focus="begin-draft" phx-value-form="comment" phx-value-revision={@drafts["comment"]["revision"]} phx-value-task_id={@task_id}><option value="" selected={@drafts["comment"]["parent_id"] == ""}>New comment</option><option :for={comment <- Enum.filter(@payload["task"]["comments"], &(&1["depth"] < 2))} value={comment["id"]} selected={@drafts["comment"]["parent_id"] == comment["id"]}>{String.slice(comment["text"], 0, 70)} ({comment["id"]})</option></select></label>
            <label>Comment<textarea name="text" required maxlength="4000" phx-focus="begin-draft" phx-value-form="comment" phx-value-revision={@drafts["comment"]["revision"]} phx-value-task_id={@task_id}>{@drafts["comment"]["text"]}</textarea></label>
            <button>Post comment</button><button :if={@drafts["comment"]["active"]} type="button" phx-click="reload-draft" phx-value-form="comment">Reload current data (discard draft)</button>
          </form>
        </section>
        <section class="detail-section"><h3>Imported agent & PR reports</h3><p class="muted">Explicit CLI/API imports. No live sync or verified merge is implied.</p>
          <article :for={report <- @payload["task"]["reports"]} class="imported-report"><strong>{report["provider"]}</strong><p>{report["author"]} · {report["at"]}</p><p>{report["reference"]}</p><a :if={report["url"]} href={report["url"]} target="_blank" rel="noopener noreferrer">Open source</a><small>{report["verification"]}</small><pre>{report["text"]}</pre></article>
        </section>
        <section class="detail-section"><h3>Pull requests & walkthroughs</h3>
          <p :if={@payload["task"]["links"] == []} class="muted">No linked evidence. No PR has been created by this demo.</p>
          <a :for={link <- @payload["task"]["links"]} class="evidence-link" href={link["url"]} target="_blank" rel="noopener noreferrer">↗ {link["title"]}<small>{link["kind"]} · {link["verification"]}</small></a>
          <div :for={link <- Enum.filter(@payload["task"]["links"], &(&1["kind"] == "walkthrough"))}>
            <p :if={Content.embed(link["url"])} class="muted">Loading this walkthrough contacts its external video provider. It remains unverified.</p>
            <button :if={Content.embed(link["url"])} phx-click="load-walkthrough" phx-value-url={link["url"]}>Load walkthrough: {link["title"]}</button>
          </div>
          <iframe :if={@embed_url} class="walkthrough-player" src={@embed_url} title="User-supplied walkthrough" loading="lazy" referrerpolicy="no-referrer" sandbox="allow-scripts allow-same-origin allow-presentation" allow="fullscreen" allowfullscreen></iframe>
          <details id="link-panel" phx-mounted={JS.ignore_attributes("open")}><summary>Add an existing evidence link</summary><form id="add-link" phx-submit="link" phx-change="draft"><input type="hidden" name="_form" value="link" /><input type="hidden" name="revision" value={@drafts["link"]["revision"]} /><input type="hidden" name="task_id" value={@task_id} />
            <label>Type<select phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} name="kind"><option value="pull_request" selected={@drafts["link"]["kind"] == "pull_request"}>Pull request</option><option value="walkthrough" selected={@drafts["link"]["kind"] == "walkthrough"}>Walkthrough</option></select></label>
            <label>Title<input phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} name="title" value={@drafts["link"]["title"]} required maxlength="160" /></label><label>HTTPS URL<input phx-focus="begin-draft" phx-value-form="link" phx-value-revision={@drafts["link"]["revision"]} phx-value-task_id={@task_id} type="url" name="url" value={@drafts["link"]["url"]} required maxlength="2000" placeholder="https://…" /></label><button>Add link</button>
          <button :if={@drafts["link"]["active"]} type="button" phx-click="reload-draft" phx-value-form="link">Reload current data (discard draft)</button></form></details>
        </section>
        <section class="detail-section"><h3>Activity <span>Durable service events</span></h3><p :if={task_events(@payload) == []} class="muted">No activity yet.</p>
          <details :for={event <- Enum.reverse(task_events(@payload))} id={"event-" <> to_string(event["cursor"])} class="activity-event"><summary><strong>{event["op"]} · {event["actor"]}</strong><time>{event["at"]}</time></summary><div :if={event["op"] == "worklog"} :for={section <- event["result"]["sections"] || []}><h4>{section["title"]}</h4><.section_nodes nodes={section["nodes"]} /></div><p :if={event["op"] == "comment"}>{event["result"]["text"]}</p><pre :if={event["op"] not in ["worklog", "comment"]}>{Jason.encode!(event, pretty: true)}</pre></details>
        </section>
      </section>
    </div>
    """
  end
end
