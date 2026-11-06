defmodule SymphonyElixirWeb.TasksLive do
  @moduledoc "Fixture queue and run controls backed by the same service as the CLI."
  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixir.Service
  @impl true
  def mount(_, session, socket) do
    token = Application.get_env(:symphony_elixir, :demo_token, "")

    if byte_size(token) >= 32 and session["demo_auth"] == SymphonyElixirWeb.DemoAuth.digest(token) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "demo")
      {:ok, socket |> assign(:error, nil) |> assign(:approval, nil) |> refresh()}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_info(:demo_updated, socket), do: {:noreply, refresh(socket)}
  @impl true
  def handle_event(op, params, socket) do
    req = %{
      "op" => op,
      "task_id" => "fixture-1",
      "run_id" => params["id"],
      "approval" => socket.assigns.approval,
      "revision" => socket.assigns.payload["task"]["revision"],
      "key" => Base.url_encode64(:crypto.strong_rand_bytes(18)),
      "scope" => "control",
      "actor" => "demo-operator"
    }

    socket =
      case Service.request(req) do
        {:ok, result} when op == "preview" -> assign(socket, approval: result["id"], error: nil)
        {:ok, _} -> assign(socket, error: nil)
        {:error, code} -> assign(socket, error: code)
      end

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    {:ok, payload} = Service.request(%{"op" => "snapshot"})
    assign(socket, :payload, payload)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="hero-card">
      <h1>Symphony task queue</h1>
      <p>Demo fixtures · simulated agents · manual dispatch · concurrency one</p>
      <p role="alert">{@error}</p>
      <h2>{@payload["task"]["title"]}</h2>
      <p>Canonical task: {@payload["task"]["status"]} · revision {@payload["task"]["revision"]} · hold: {to_string(@payload["task"]["hold"])}</p>
      <p>Production release: unverified. Resume is not supported.</p>
      <button :for={action <- @payload["task"]["allowed_actions"]} phx-click={action}>{action}</button>
      <p :if={@approval}>Preview {@approval}: fixture only; expires after two minutes. No commit, push or deployment authorized.</p>
      <button :if={@approval && @payload["runs"] == []} phx-click="start">Approve and start simulation</button>
      <article :for={run <- @payload["runs"]} id={"run-" <> run["id"]}>
        <h3>Run {run["id"]}</h3>
        <p>{run["state"]} · attempt {run["attempt"]} · parent {run["parent_id"]}</p>
        <button :if={run["state"] in ["starting", "running"]} phx-click="stop" phx-value-id={run["id"]}>Stop and hold</button>
        <button :if={@approval && run["state"] not in ["starting", "running", "stopping"]} phx-click="retry" phx-value-id={run["id"]}>Approve new retry</button>
        <pre>{Jason.encode!(run["evidence"], pretty: true)}</pre>
      </article>
      <h2>Durable history and simulation logs</h2>
      <pre :for={event <- @payload["events"]}>{Jason.encode!(event)}</pre>
    </section>
    """
  end
end
