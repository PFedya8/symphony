defmodule SymphonyElixirWeb.DemoAuth do
  @moduledoc "Local demo authentication. Tokens are never persisted in history."
  import Plug.Conn
  @spec init(term()) :: term()
  def init(opts), do: opts
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _) do
    enabled = Application.get_env(:symphony_elixir, :demo, false)

    if enabled, do: authenticate(conn), else: send_resp(conn, 404, "disabled") |> halt()
  end

  defp authenticate(conn) do
    token = Application.get_env(:symphony_elixir, :demo_token)
    bearer = get_req_header(conn, "authorization") == ["Bearer #{token}"]
    basic = Plug.BasicAuth.parse_basic_auth(conn) == {"demo", token}

    browser = basic and not String.starts_with?(conn.request_path, "/api/")

    if is_binary(token) and byte_size(token) >= 32 and (bearer or browser) do
      conn |> assign(:demo_actor, "demo-operator") |> put_session(:demo_auth, digest(token))
    else
      conn |> put_resp_header("www-authenticate", "Basic realm=Symphony demo") |> send_resp(401, "unauthorized") |> halt()
    end
  end

  @spec digest(String.t()) :: String.t()
  def digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16()
end
