# Run with mix run --no-start demo.exs. Local-only fixture control plane.
token = System.fetch_env!("SYMPHONY_DEMO_TOKEN")
if byte_size(token) < 32, do: raise("SYMPHONY_DEMO_TOKEN must contain at least 32 bytes")
Application.put_env(:symphony_elixir, :demo, true)
Application.put_env(:symphony_elixir, :demo_token, token)
Application.put_env(:symphony_elixir, :demo_db, System.fetch_env!("SYMPHONY_DEMO_DB"))
Application.put_env(:symphony_elixir, :workflow_file_path, Path.expand("demo-workflow.md", __DIR__))
{:ok, _} = Application.ensure_all_started(:symphony_elixir)
Process.sleep(:infinity)
