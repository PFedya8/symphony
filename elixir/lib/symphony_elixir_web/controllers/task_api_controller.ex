defmodule SymphonyElixirWeb.TaskApiController do
  @moduledoc "Thin authenticated API for the shared manual service."
  use Phoenix.Controller, formats: [:json]
  @spec read(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read(conn, params) do
    op = params["view"] || "snapshot"
    request = %{"op" => op, "task_id" => params["task_id"]}
    request = if params["cursor"], do: Map.put(request, "cursor", parse_cursor(params["cursor"])), else: request
    respond(conn, SymphonyElixir.Service.request(request))
  end

  @spec command(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def command(conn, params) do
    request = params |> Map.put("scope", "control") |> Map.put("actor", conn.assigns.demo_actor)
    respond(conn, SymphonyElixir.Service.request(request))
  end

  defp respond(conn, {:ok, payload}), do: json(conn, payload)
  defp respond(conn, {:error, code}), do: conn |> put_status(if(code == "forbidden", do: 403, else: 409)) |> json(%{error: %{code: code}})

  defp parse_cursor(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end
end
