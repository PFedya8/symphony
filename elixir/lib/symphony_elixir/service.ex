defmodule SymphonyElixir.Service do
  @moduledoc "Shared UI/API command boundary; the existing orchestrator owns all execution."
  @spec request(map(), GenServer.server()) :: {:ok, map()} | {:error, String.t()}
  def request(request, server \\ Application.get_env(:symphony_elixir, :demo_server, SymphonyElixir.Orchestrator)) do
    GenServer.call(server, {:demo, request})
  catch
    :exit, _ -> {:error, "unavailable"}
  end
end
