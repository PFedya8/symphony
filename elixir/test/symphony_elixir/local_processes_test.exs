defmodule SymphonyElixir.LocalProcessesTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.LocalProcesses

  test "owner death and explicit close remove background work; stopping owners cannot relaunch" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, port} = LocalProcesses.open(System.find_executable("bash"), [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", ~c"sleep 30 & wait"], line: 1024])
        send(parent, {:owned, port})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned, port}
    Process.exit(owner, :kill)
    wait_empty()
    opts = [:binary, args: [~c"-c", ~c"true"], line: 1024]
    assert {:error, :worker_stopping} = LocalProcesses.open(System.find_executable("bash"), opts, owner)
    assert :ok = LocalProcesses.close(port)
    send(LocalProcesses, {port, {:data, {:eol, "late"}}})
    assert :ok = LocalProcesses.stop_owner(self())
    assert {:error, :worker_stopping} = LocalProcesses.open(System.find_executable("bash"), [:binary, args: [~c"-c", ~c"true"], line: 1024])
    assert {"worker stopping", 125} = LocalProcesses.run_hook("true", "/tmp", self())
  end

  test "managed hooks return output and supervisor shutdown kills owned groups" do
    assert {"line\n", 0} = LocalProcesses.run_hook("printf 'line\\n'", "/tmp", self())
    assert {"hello", 0} = LocalProcesses.run_hook("printf hello", "/tmp", self())
    {:ok, _} = LocalProcesses.open(System.find_executable("bash"), [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", ~c"sleep 30 & wait"], line: 1024])
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, LocalProcesses)
    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, LocalProcesses)
    wait_empty()
  end

  test "premature raw port closure still cleans up its owned process group" do
    opts = [:binary, :exit_status, :stderr_to_stdout, args: [~c"-c", ~c"sleep 30 & wait"], line: 1024]
    {:ok, port} = LocalProcesses.open(System.find_executable("bash"), opts)
    Port.close(port)
    wait_empty()
    assert :ok = LocalProcesses.close(port)
  end

  test "a failed process-group handshake fails closed" do
    root = Path.join(System.tmp_dir!(), "synthetic-setsid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "setsid"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(root, "setsid"), 0o755)
    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(root)
    end)

    System.put_env("PATH", root <> ":" <> path)
    assert catch_exit(LocalProcesses.open("/bin/bash", [:binary, :exit_status, args: [~c"-c", ~c"true"], line: 1024]))
    System.put_env("PATH", path)
    wait_started()
  end

  defp wait_started(tries \\ 100)
  defp wait_started(0), do: assert(is_pid(Process.whereis(LocalProcesses)))

  defp wait_started(tries) do
    unless is_pid(Process.whereis(LocalProcesses)) do
      Process.sleep(10)
      wait_started(tries - 1)
    end
  end

  defp wait_empty(tries \\ 100)
  defp wait_empty(0), do: assert(:sys.get_state(LocalProcesses).ports == %{})

  defp wait_empty(tries) do
    if :sys.get_state(LocalProcesses).ports != %{} do
      Process.sleep(10)
      wait_empty(tries - 1)
    end
  end
end
