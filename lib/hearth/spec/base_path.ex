defmodule Hearth.Spec.BasePath do
  @moduledoc false

  # Finds the longest leading path-segment sequence shared by every
  # operation — `/api/v1/customers`, `/api/v1/subscriptions`, … →
  # `/api/v1`. The gen task folds that prefix into the generated
  # Layer 1 `@base_url` and strips it from each operation path, so
  # Layer 3 call sites stay short: `request("/customers", …)` rather
  # than `request("/api/v1/customers", …)`.
  #
  # The prefix never consumes a whole operation path — every stripped
  # path keeps at least one segment.

  alias Hearth.Spec.Operation

  @doc """
  The common leading path prefix of `operations`, e.g. `"/api/v1"`.

  Returns `""` when the operations share no leading segment, when the
  shortest path is a single segment, or when the list is empty.
  """
  @spec common_prefix([Operation.t()]) :: String.t()
  def common_prefix([]), do: ""

  def common_prefix(operations) do
    seg_lists = Enum.map(operations, &segments(&1.path))
    # Cap one short of the shortest path so every operation keeps a
    # segment of its own after stripping.
    max_len = (seg_lists |> Enum.map(&length/1) |> Enum.min()) - 1

    if max_len <= 0 do
      ""
    else
      seg_lists
      |> Enum.reduce(&common_leading/2)
      |> Enum.take(max_len)
      |> prefix_string()
    end
  end

  @doc """
  Drops `prefix` from the front of every operation's path.

  A `""` prefix returns `operations` unchanged. `prefix` must be a
  leading path of every operation, as `common_prefix/1` guarantees.
  """
  @spec strip([Operation.t()], String.t()) :: [Operation.t()]
  def strip(operations, ""), do: operations

  def strip(operations, prefix) do
    drop = prefix |> segments() |> length()
    Enum.map(operations, &strip_one(&1, drop))
  end

  defp strip_one(%Operation{path: path} = op, drop) do
    %{op | path: path |> segments() |> Enum.drop(drop) |> path_string()}
  end

  defp common_leading(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map(&elem(&1, 0))
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp prefix_string([]), do: ""
  defp prefix_string(segs), do: "/" <> Enum.join(segs, "/")

  defp path_string([]), do: "/"
  defp path_string(segs), do: "/" <> Enum.join(segs, "/")
end
