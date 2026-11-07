defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitLab.Client, as: GitLabClient
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    config = Config.settings!()
    environment = System.get_env()
    tracker_settings = config.tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      board_policy: board_policy(config, environment),
      board_generation: if(config.board.enabled, do: SymphonyElixir.RuntimeBoard.configuration_fingerprint(config, environment)),
      tracker_settings: freeze_provider(tracker_settings, environment),
      tool_specs: adapter_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings} = binding,
        tool,
        arguments,
        opts \\ []
      ) do
    if binding_current?(binding) and board_tool_allowed?(Map.get(binding, :board_policy, :standard), tool, arguments) do
      execute_agent_tool_with_adapter(adapter, tool, arguments, Keyword.put(opts, :tracker_settings, tracker_settings))
    else
      unsupported_agent_tool_response("board scope changed or request outside configured-project read policy")
    end
  end

  defp freeze_provider(%{kind: "gitlab"} = tracker, environment) do
    case GitLabClient.bind_settings(tracker, environment) do
      {:ok, settings} -> settings
      {:error, _} -> raise ArgumentError, "Cannot bind invalid GitLab provider settings"
    end
  end

  defp freeze_provider(tracker, _environment), do: tracker

  defp binding_current?(binding) do
    case Map.get(binding, :board_generation) do
      nil ->
        true

      generation ->
        with :ok <- Config.validate!(), {:ok, config} <- Config.settings() do
          generation == SymphonyElixir.RuntimeBoard.configuration_fingerprint(config)
        else
          _ -> false
        end
    end
  end

  defp board_policy(%{board: %{enabled: false}}, _environment), do: :standard

  defp board_policy(config, environment) do
    project =
      case config.tracker.provider["project_path"] do
        "$" <> name -> environment[name] || environment["GITLAB_PROJECT_PATH"]
        nil -> environment["GITLAB_PROJECT_PATH"]
        value -> value
      end

    {:gitlab_read_only, project || ""}
  end

  defp board_tool_allowed?(:standard, _, _), do: true

  defp board_tool_allowed?({:gitlab_read_only, project}, "gitlab_api", %{"method" => method, "path" => path} = args)
       when is_binary(method) and is_binary(path) do
    prefix = "/projects/" <> URI.encode_www_form(project)
    suffix = String.replace_prefix(path, prefix, "")

    project != "" and String.upcase(String.trim(method)) == "GET" and args["body"] in [nil, %{}] and
      String.starts_with?(path, prefix <> "/") and
      Regex.match?(~r/\A\/(issues|merge_requests)(\/[1-9][0-9]*)?(\/(notes|changes|commits|discussions))?\z/, suffix)
  end

  defp board_tool_allowed?(_, _, _), do: false

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
