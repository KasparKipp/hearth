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
  # Parameters: local `#/components/parameters/*` refs are resolved; an
  # operation-level param overrides a path-item-level one with the same
  # `name` + `in` (per the OAS spec); and every `{x}` in the path
  # template becomes a path param even when undeclared, so the
  # generated URL can always interpolate it. Other refs (external,
  # missing) stay unresolved and unclassified.

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
    component_params = component_params(spec)

    spec
    |> Map.get("paths", %{})
    |> Enum.flat_map(&extract_path(&1, component_params))
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

  @doc false
  # Lowercases, splits camelCase, and collapses every run of
  # non-alphanumeric characters (hyphens, dots, spaces, repeated
  # underscores) into a single underscore, so the result is always a
  # valid Elixir function name. Public so `Hearth.Spec.Filter` can
  # normalize user-supplied operationIds the same way `:id` is derived.
  @spec sanitize_id(String.t()) :: String.t()
  def sanitize_id(string) when is_binary(string) do
    string
    |> Macro.underscore()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp component_params(spec) do
    case spec["components"] do
      %{"parameters" => %{} = params} -> params
      _ -> %{}
    end
  end

  defp extract_path({path, path_item}, component_params)
       when is_binary(path) and is_map(path_item) do
    shared_params = resolve_all(Map.get(path_item, "parameters", []), component_params)

    path_item
    |> Map.take(@http_methods)
    |> Enum.map(fn {method, operation} ->
      own_params = resolve_all(Map.get(operation, "parameters", []), component_params)
      build_operation(path, method, operation, merge_params(shared_params, own_params))
    end)
  end

  defp extract_path(_, _component_params), do: []

  defp build_operation(path, method, operation, params) do
    %__MODULE__{
      id: nil,
      operation_id: Map.get(operation, "operationId"),
      method: Map.fetch!(@methods, method),
      path: path,
      path_params: params |> params_in("path") |> with_template_params(path),
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

  defp resolve_all(params, component_params) when is_list(params) do
    Enum.map(params, &resolve(&1, component_params))
  end

  defp resolve_all(_params, _component_params), do: []

  defp resolve(%{"$ref" => "#/components/parameters/" <> name} = param, component_params) do
    case Map.get(component_params, name) do
      %{} = resolved -> resolved
      _ -> param
    end
  end

  defp resolve(param, _component_params), do: param

  # Operation-level params replace path-item-level ones with the same
  # `name` + `in` in place (keeping declaration order); the rest of the
  # operation's params follow.
  defp merge_params(shared, own) do
    overrides = Map.new(own, &{param_key(&1), &1})
    shared_keys = MapSet.new(shared, &param_key/1)

    Enum.map(shared, &Map.get(overrides, param_key(&1), &1)) ++
      Enum.reject(own, &MapSet.member?(shared_keys, param_key(&1)))
  end

  defp param_key(%{"name" => name, "in" => location}), do: {name, location}
  defp param_key(param), do: param

  # Appends a synthesized path param for every `{name}` in the template
  # that no declared param covers, in template order.
  defp with_template_params(declared, path) do
    declared_names = MapSet.new(declared, & &1["name"])

    undeclared =
      ~r/\{([^}]+)\}/
      |> Regex.scan(path, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(declared_names, &1))
      |> Enum.map(&%{"name" => &1, "in" => "path"})

    declared ++ undeclared
  end

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
    sanitize_id(id)
  end

  defp base_id(%__MODULE__{method: method, path: path}) do
    # Replace path separators and param braces with spaces; `sanitize_id/1`
    # collapses them (and any other non-alphanumerics) into underscores.
    slug = String.replace(path, ~r"[/{}]", " ")
    sanitize_id("#{method} #{slug}")
  end

  defp dedupe(base, seen) do
    case Map.get(seen, base, 0) do
      0 -> {base, Map.put(seen, base, 1)}
      n -> {"#{base}_#{n + 1}", Map.put(seen, base, n + 1)}
    end
  end
end
