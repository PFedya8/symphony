defmodule SymphonyElixir.Demo.Store do
  @moduledoc "SQLite snapshot store. One exclusive connection fences other service instances."
  alias Exqlite.Sqlite3, as: SQL

  @spec open(String.t()) :: {reference(), map() | nil}
  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = SQL.open(path)
    :ok = SQL.execute(db, "PRAGMA locking_mode=EXCLUSIVE; PRAGMA synchronous=FULL;")
    :ok = SQL.execute(db, "CREATE TABLE IF NOT EXISTS demo_state (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, body TEXT NOT NULL)")
    {:ok, stmt} = SQL.prepare(db, "SELECT version, body FROM demo_state WHERE id=1")
    row = SQL.step(db, stmt)
    :ok = SQL.release(db, stmt)

    data =
      case row do
        :done -> nil
        {:row, [version, json]} when version in [1, 2] -> Jason.decode!(json)
        _ -> raise "Unsupported demo database schema; restore a compatible backup"
      end

    {db, data}
  end

  @spec save(reference(), map()) :: :ok
  def save(db, data) do
    :ok = SQL.execute(db, "BEGIN IMMEDIATE")
    {:ok, stmt} = SQL.prepare(db, "INSERT OR REPLACE INTO demo_state VALUES (1, 2, ?)")
    :ok = SQL.bind(stmt, [Jason.encode!(data)])
    :done = SQL.step(db, stmt)
    :ok = SQL.release(db, stmt)
    :ok = SQL.execute(db, "COMMIT")
  end
end
