defmodule Hearth.Spec.Operation do
  @moduledoc false

  # A normalized OpenAPI operation, flattened out of the nested
  # `paths → <path> → <method>` shape of a decoded spec.
  #
  # `:id` is the snake_case function name Hearth will generate. It is
  # always present: `operationId` underscored when the spec provides
  # one, otherwise derived from `<verb>_<path-slug>`. Collisions across
  # the operation list are resolved with numeric suffixes
  # (`create_user`, `create_user_2`).
  #
  # `$ref` resolution is out of scope here — parameters that are bare
  # `$ref` maps (no `"in"` key) are simply not classified as path or
  # query params. That lands with schema resolution in a later step.

  @methods %{
    "get" => :get,
    "put" => :put,
    "post" => :post,
    "delete" => :delete,
    "options" => :options,
    "head" => :head,
    "patch" => :patch,
    "trace" => :trace
  }

  @http_methods Map.keys(@methods)

  defstruct [
    :id,
    :operation_id,
    :method,
    :path,
    :path_params,
    :query_params,
    :request_body,
    :tags,
    :summary,
    :description
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          operation_id: String.t() | nil,
          method: atom(),
          path: String.t(),
          path_params: [map()],
          query_params: [map()],
          request_body: map() | nil,
          tags: [String.t()],
          summary: String.t() | nil,
          description: String.t() | nil
        }

  @spec extract(map()) :: [t()]
  def extract(spec) when is_map(spec) do
    spec
    |> Map.get("paths", %{})
    |> Enum.flat_map(&extract_path/1)
    |> assign_ids()
  end

  @spec tag_index([t()]) :: %{(String.t() | :untagged) => [t()]}
  def tag_index(operations) when is_list(operations) do
    operations
    |> Enum.reduce(%{}, fn op, acc ->
      tags = if op.tags == [], do: [:untagged], else: op.tags
      Enum.reduce(tags, acc, &Map.update(&2, &1, [op], fn ops -> [op | ops] end))
    end)
    |> Map.new(fn {tag, ops} -> {tag, Enum.reverse(ops)} end)
  end

  defp extract_path({path, path_item}) when is_binary(path) and is_map(path_item) do
    shared_params = Map.get(path_item, "parameters", [])

    path_item
    |> Map.take(@http_methods)
    |> Enum.map(fn {method, operation} ->
      build_operation(path, method, operation, shared_params)
    end)
  end

  defp extract_path(_), do: []

  defp build_operation(path, method, operation, shared_params) do
    params = shared_params ++ Map.get(operation, "parameters", [])

    %__MODULE__{
      id: nil,
      operation_id: Map.get(operation, "operationId"),
      method: Map.fetch!(@methods, method),
      path: path,
      path_params: params_in(params, "path"),
      query_params: params_in(params, "query"),
      request_body: Map.get(operation, "requestBody"),
      tags: Map.get(operation, "tags", []),
      summary: Map.get(operation, "summary"),
      description: Map.get(operation, "description")
    }
  end

  defp params_in(params, location) when is_list(params) do
    Enum.filter(params, fn param -> is_map(param) and param["in"] == location end)
  end

  defp params_in(_params, _location), do: []

  # Assigns the final `:id` to each operation in spec order, suffixing
  # later duplicates of a base name with `_2`, `_3`, …
  defp assign_ids(operations) do
    {assigned, _seen} =
      Enum.map_reduce(operations, %{}, fn op, seen ->
        {id, seen} = dedupe(base_id(op), seen)
        {%{op | id: id}, seen}
      end)

    assigned
  end

  defp base_id(%__MODULE__{operation_id: id}) when is_binary(id) and id != "" do
    sanitize(id)
  end

  defp base_id(%__MODULE__{method: method, path: path}) do
    # Replace path separators and param braces with spaces; `sanitize/1`
    # collapses them (and any other non-alphanumerics) into underscores.
    slug = String.replace(path, ~r"[/{}]", " ")
    sanitize("#{method} #{slug}")
  end

  # Lowercases, splits camelCase, and collapses every run of
  # non-alphanumeric characters (hyphens, dots, spaces, repeated
  # underscores) into a single underscore so the result is always a
  # valid Elixir function name.
  defp sanitize(string) do
    string
    |> Macro.underscore()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp dedupe(base, seen) do
    case Map.get(seen, base, 0) do
      0 -> {base, Map.put(seen, base, 1)}
      n -> {"#{base}_#{n + 1}", Map.put(seen, base, n + 1)}
    end
  end
end
