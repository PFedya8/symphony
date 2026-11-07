defmodule SymphonyElixir.ChildEnvironment do
  @moduledoc "Keeps operator control credentials out of subprocess environments."
  @controls ~w(SYMPHONY_BOARD_TOKEN SYMPHONY_DEMO_TOKEN)

  @spec names([String.t()]) :: [String.t()]
  def names(additional \\ []) do
    secrets =
      [Application.get_env(:symphony_elixir, :demo_token) | Enum.map(@controls ++ additional, &System.get_env/1)]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    aliases = for {name, value} <- System.get_env(), value in secrets, do: name

    (@controls ++ additional ++ aliases)
    |> Enum.filter(&(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)))
    |> Enum.uniq()
  end

  @spec system_env() :: [{String.t(), nil}]
  def system_env, do: Enum.map(names(), &{&1, nil})

  @spec port_env([String.t()]) :: [{charlist(), false}]
  def port_env(additional \\ []), do: Enum.map(names(additional), &{String.to_charlist(&1), false})

  @spec command(String.t(), [String.t()]) :: String.t()
  def command(command, additional \\ []), do: "unset " <> Enum.join(names(additional), " ") <> " && " <> command
end
