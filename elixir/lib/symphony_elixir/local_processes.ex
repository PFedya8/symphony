defmodule SymphonyElixir.LocalProcesses do
  @moduledoc "Owns local board app-server process groups independently of worker task lifetimes."
  use GenServer
  alias SymphonyElixir.ChildEnvironment

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @spec open(String.t(), list(), pid()) :: {:ok, port()} | {:error, :worker_stopping}
  def open(executable, opts, lifetime_owner \\ self()), do: GenServer.call(__MODULE__, {:open, lifetime_owner, self(), executable, opts}, 10_000)
  @spec stop_owner(pid()) :: :ok
  def stop_owner(owner), do: GenServer.call(__MODULE__, {:stop_owner, owner})
  @spec close(port()) :: :ok
  def close(port), do: GenServer.call(__MODULE__, {:close, port})

  @spec run_hook(String.t(), String.t(), pid()) :: {String.t(), integer()}
  def run_hook(command, workspace, owner) do
    opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: [~c"-lc", String.to_charlist(ChildEnvironment.command(command))],
      cd: String.to_charlist(workspace),
      env: ChildEnvironment.port_env(),
      line: 65_536
    ]

    case open(System.find_executable("bash"), opts, owner) do
      {:ok, port} -> collect(port, "")
      {:error, :worker_stopping} -> {"worker stopping", 125}
    end
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, {:eol, line}}} -> collect(port, output <> line <> "\n")
      {^port, {:data, {:noeol, line}}} -> collect(port, output <> line)
      {^port, {:exit_status, status}} -> {output, status}
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{ports: %{}, stopping: MapSet.new()}}
  end

  @impl true
  def handle_call({:open, owner, recipient, executable, opts}, _, state) do
    if MapSet.member?(state.stopping, owner) or not Process.alive?(owner) do
      {:reply, {:error, :worker_stopping}, state}
    else
      # setsid may fork when the Erlang port child is already a group leader.
      # The trusted wrapper reports its actual session leader before exec.
      args = [
        ~c"--wait",
        String.to_charlist(executable),
        ~c"-c",
        ~c"printf '__SYMPHONY_GROUP__:%s\\n' \"$$\"; exec \"$@\"",
        ~c"symphony-group",
        String.to_charlist(executable) | Keyword.fetch!(opts, :args)
      ]

      port = Port.open({:spawn_executable, String.to_charlist(System.find_executable("setsid"))}, [:eof | List.keyreplace(opts, :args, 0, {:args, args})])
      {:os_pid, pid} = Port.info(port, :os_pid)

      group =
        receive do
          {^port, {:data, {:eol, "__SYMPHONY_GROUP__:" <> value}}} -> String.to_integer(value)
        after
          5000 ->
            close_port(port)
            raise "Local process group handshake failed"
        end

      entry = %{
        owner: owner,
        recipient: recipient,
        monitor: Process.monitor(owner),
        recipient_monitor: Process.monitor(recipient),
        pid: pid,
        group: group,
        status: nil,
        eof: false
      }

      {:reply, {:ok, port}, put_in(state.ports[port], entry)}
    end
  end

  def handle_call({:close, port}, _, state), do: {:reply, :ok, release(state, port)}

  def handle_call({:stop_owner, owner}, _, state) do
    Process.monitor(owner)
    state = %{state | stopping: MapSet.put(state.stopping, owner)}
    {:reply, :ok, release_owner(state, owner)}
  end

  @impl true
  def handle_info({:DOWN, _, :process, owner, _}, state) do
    state = release_owner(state, owner)
    {:noreply, %{state | stopping: MapSet.delete(state.stopping, owner)}}
  end

  def handle_info({port, message}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      entry ->
        case message do
          {:exit_status, status} ->
            kill!("-#{entry.group}")
            {:noreply, finish_if_drained(put_in(state.ports[port].status, status), port)}

          :eof ->
            {:noreply, finish_if_drained(put_in(state.ports[port].eof, true), port)}

          _ ->
            send(entry.recipient, {port, message})
            {:noreply, state}
        end
    end
  end

  def handle_info({:EXIT, port, _}, state) do
    if entry = state.ports[port], do: send(entry.recipient, {port, {:exit_status, 125}})
    {:noreply, release(state, port)}
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.ports, fn {port, _} -> release(state, port) end)
  end

  defp finish_if_drained(state, port) do
    entry = state.ports[port]

    if entry.eof and is_integer(entry.status) do
      send(entry.recipient, {port, {:exit_status, entry.status}})
      release(state, port)
    else
      state
    end
  end

  defp release_owner(state, owner) do
    Enum.reduce(state.ports, state, fn {port, entry}, acc -> if entry.owner == owner or entry.recipient == owner, do: release(acc, port), else: acc end)
  end

  defp release(state, port) do
    case Map.pop(state.ports, port) do
      {nil, _} ->
        state

      {entry, ports} ->
        # A dedicated session/group includes descendants which retain their inherited group.
        # KILL does not depend on an app-server cooperating with stdin closure or TERM.
        kill!("-#{entry.group}")
        close_port(port)

        Process.demonitor(entry.monitor, [:flush])
        Process.demonitor(entry.recipient_monitor, [:flush])
        %{state | ports: ports}
    end
  end

  defp kill!(target) do
    case System.cmd("kill", ["-KILL", "--", target], stderr_to_stdout: true, env: [{"LC_ALL", "C"} | ChildEnvironment.system_env()]) do
      {_, 0} -> :ok
      {output, _} -> if String.contains?(output, "No such process"), do: :ok, else: raise("Local process termination failed")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
