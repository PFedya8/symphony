defmodule SymphonyElixirWeb.DemoAuth do
  @moduledoc "Local demo authentication. Tokens are never persisted in history."
  import Plug.Conn
  @spec init(term()) :: term()
  def init(opts), do: opts
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _) do
    enabled = Application.get_env(:symphony_elixir, :demo, false) or runtime_enabled?()

    if enabled, do: authenticate(conn), else: send_resp(conn, 404, "disabled") |> halt()
  end

  defp authenticate(conn) do
    token = token()
    bearer = get_req_header(conn, "authorization") == ["Bearer #{token}"]
    basic = Plug.BasicAuth.parse_basic_auth(conn) == {"demo", token}

    browser = basic and not String.starts_with?(conn.request_path, "/api/")

    if is_binary(token) and byte_size(token) >= 32 and (bearer or browser) do
      conn |> assign(:demo_actor, actor()) |> put_session(:demo_auth, digest(token))
    else
      conn |> put_resp_header("www-authenticate", "Basic realm=Symphony demo") |> send_resp(401, "unauthorized") |> halt()
    end
  end

  @spec token() :: String.t() | nil
  def token do
    cond do
      Application.get_env(:symphony_elixir, :demo, false) -> Application.get_env(:symphony_elixir, :demo_token)
      runtime_enabled?() -> System.get_env("SYMPHONY_BOARD_TOKEN")
      true -> nil
    end
  end

  @spec actor() :: String.t()
  def actor, do: if(Application.get_env(:symphony_elixir, :demo, false), do: "demo-operator", else: "board-operator")

  defp runtime_enabled? do
    case SymphonyElixir.Config.settings() do
      {:ok, %{board: %{enabled: enabled}}} -> enabled
      _ -> false
    end
  end

  @spec digest(String.t()) :: String.t()
  def digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16()
end
