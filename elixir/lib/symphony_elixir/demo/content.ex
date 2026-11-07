defmodule SymphonyElixir.Demo.Content do
  @moduledoc "Bounded plain-text authored sections and provider allowlisted walkthrough URLs."

  @spec sections(map()) :: [map()]
  def sections(params) do
    Enum.map([{"plan_text", "Plan"}, {"acceptance_text", "Acceptance Criteria"}, {"validation_text", "Validation"}], fn {key, title} ->
      text = params[key]
      ensure(is_binary(text) and byte_size(text) in 1..4000)
      lines = String.split(text, "\n", trim: true)
      ensure(length(lines) in 1..50)

      nodes =
        Enum.reduce(lines, [], fn line, nodes ->
          trimmed = String.trim_leading(line, " ")
          spaces = byte_size(line) - byte_size(trimmed)
          ensure(spaces in [0, 2, 4] and byte_size(trimmed) in 1..500 and String.trim(trimmed) != "")
          append(nodes, div(spaces, 2), trimmed)
        end)

      %{"title" => title, "nodes" => nodes}
    end)
  end

  defp append(nodes, 0, text), do: nodes ++ [%{"text" => text, "children" => []}]
  defp append([], _, _), do: throw({:reject, "invalid_sections"})
  defp append(nodes, depth, text), do: List.update_at(nodes, -1, &Map.update!(&1, "children", fn children -> append(children, depth - 1, text) end))
  defp ensure(true), do: :ok
  defp ensure(_), do: throw({:reject, "invalid_sections"})

  @spec embed(String.t()) :: String.t() | nil
  def embed(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.userinfo == nil and uri.port == 443 do
      canonical_embed(uri.host, uri.path || "", URI.decode_query(uri.query || ""))
    end
  end

  defp canonical_embed(host, path, query) when host in ["vimeo.com", "player.vimeo.com"] do
    id = String.replace_prefix(path, "/video/", "/") |> String.trim_leading("/")
    hash = query["h"]

    if Regex.match?(~r/\A[0-9]{1,15}\z/, id) and (is_nil(hash) or Regex.match?(~r/\A[a-zA-Z0-9]{1,64}\z/, hash)) do
      "https://player.vimeo.com/video/" <> id <> if(hash, do: "?h=" <> hash, else: "")
    end
  end

  defp canonical_embed(host, path, query) when host in ["youtube.com", "www.youtube.com", "youtu.be"] do
    id = if host == "youtu.be", do: String.trim_leading(path, "/"), else: if(path == "/watch", do: query["v"], else: nil)
    if is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]{11}\z/, id), do: "https://www.youtube-nocookie.com/embed/" <> id
  end

  defp canonical_embed(_, _, _), do: nil
end
