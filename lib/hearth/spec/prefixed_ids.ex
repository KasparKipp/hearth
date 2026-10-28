defmodule Hearth.Spec.PrefixedIds do
  @moduledoc false

  # An integration's `prefixed_ids:` in `.hearth.exs` — functions that
  # take a type-prefixed resource id (Stripe's `cus_…`, `sub_…`) and
  # work out its path, so a few functions cover every resource:
  #
  #     prefixed_ids: [
  #       functions: [retrieve: :get, update: :post, delete: :delete],
  #       prefixes: [
  #         cus: "GetCustomersCustomer",          # an operation a function calls
  #         pi: "/v1/payment_intents/{intent}"    # or its path
  #       ]
  #     ]
  #
  # `StripeApi.retrieve("cus_123")` → `GET /customers/cus_123`. A
  # prefix matches ids that start with it and `_`. Its resource path
  # must have exactly one path parameter, which the id fills. Function
  # names are the user's; each maps to an HTTP method, and works for the
  # prefixes whose resource has that method. `functions` defaults to
  # `[retrieve: :get]`.
  #
  # Pure: the renderers and tasks take the resolved resources.

  alias Hearth.Spec.Operation

  @methods [:get, :post, :put, :patch, :delete]

  # The HTTP methods a function can map to.
  @spec methods() :: [atom()]
  def methods, do: @methods

  @type t :: %{functions: [{atom(), atom()}], prefixes: [{String.t(), String.t()}]}
  @type resource :: %{prefix: String.t(), path: String.t(), methods: [atom()]}

  # `Hearth.Config.Schema` has checked the shape.
  @spec parse(keyword()) :: t() | nil
  def parse(entry) do
    with config when is_list(config) <- entry[:prefixed_ids] do
      prefixes = for {prefix, target} <- config[:prefixes], do: {Atom.to_string(prefix), target}
      %{functions: Keyword.get(config, :functions, retrieve: :get), prefixes: prefixes}
    end
  end

  # Each prefix's resource: its path and the methods the spec has there.
  # A prefix naming an operation must name one a function calls: the
  # pruned spec keeps only those, and regen resolves against it.
  @spec resolve(map(), t()) :: {:ok, [resource()]} | {:error, String.t()}
  def resolve(spec, %{prefixes: prefixes, functions: functions}) do
    paths = spec["paths"] || %{}
    operations = Operation.extract(spec)
    used = functions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Enum.reduce_while(prefixes, {:ok, []}, fn {prefix, target}, {:ok, acc} ->
      case resource(paths, {operations, used}, prefix, target) do
        {:ok, resource} -> {:cont, {:ok, acc ++ [resource]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # For the tasks: the entry's `prefixed_ids:` resolved against `spec`,
  # as `%{functions:, resources:}` — or nil when the entry has none.
  @spec prepare(map(), keyword()) :: {:ok, map() | nil} | {:error, String.t()}
  def prepare(spec, entry) do
    case parse(entry) do
      nil ->
        {:ok, nil}

      config ->
        with {:ok, resources} <- resolve(spec, config),
             do: {:ok, %{functions: config.functions, resources: resources}}
    end
  end

  # Function names that a generated operation function already uses.
  @spec clashes(map() | nil, [Operation.t()]) :: [atom()]
  def clashes(nil, _operations), do: []

  def clashes(%{functions: functions}, operations) do
    ids = MapSet.new(operations, & &1.id)
    for {name, _method} <- functions, MapSet.member?(ids, Atom.to_string(name)), do: name
  end

  # The operations the functions call — kept in the pruned spec even when
  # not selected, so their paths (and drift) stay known.
  @spec targets([Operation.t()], [resource()], [{atom(), atom()}]) :: [Operation.t()]
  def targets(operations, resources, functions) do
    used = functions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    paths = MapSet.new(resources, & &1.path)

    Enum.filter(operations, &(MapSet.member?(paths, &1.path) and &1.method in used))
  end

  # The operations a prefixed function reaches — never generated as
  # functions of their own, selected or not. Each with the function that
  # covers it.
  @spec covered([Operation.t()], map() | nil) :: [{Operation.t(), atom()}]
  def covered(_operations, nil), do: []

  def covered(operations, %{resources: resources, functions: functions}) do
    for op <- targets(operations, resources, functions) do
      {name, _method} = Enum.find(functions, fn {_name, method} -> method == op.method end)
      {op, name}
    end
  end

  # For each function, the prefixes it works for.
  @spec pairs([resource()], [{atom(), atom()}]) :: [{atom(), [String.t()]}]
  def pairs(resources, functions) do
    for {name, method} <- functions do
      {name, for(r <- resources, method in r.methods, do: r.prefix)}
    end
  end

  defp resource(paths, _operations_used, prefix, "/" <> _ = path) do
    if is_map(paths[path]),
      do: checked(prefix, path, paths[path]),
      else: {:error, "#{label(prefix)} names the path #{path}, which the spec doesn't have."}
  end

  defp resource(paths, {operations, used}, prefix, operation_id) do
    case Enum.find(operations, &(&1.operation_id == operation_id)) do
      nil ->
        {:error,
         "#{label(prefix)} names the operation #{inspect(operation_id)}, which the spec doesn't have."}

      operation ->
        if operation.method in used,
          do: checked(prefix, operation.path, paths[operation.path]),
          else: {:error, uncalled_message(prefix, operation, operations, used)}
    end
  end

  # Points at an operation on the same path that a function does call,
  # if the spec has one, and at the path.
  defp uncalled_message(prefix, operation, operations, used) do
    called =
      Enum.find_value(used, fn method ->
        Enum.find_value(operations, fn op ->
          op.path == operation.path and op.method == method and op.operation_id
        end)
      end)

    instead = if called, do: "an operation a function calls (#{called}) or by ", else: ""

    "#{label(prefix)} names #{operation.operation_id} (#{operation.method} #{operation.path}), " <>
      "but no function uses #{inspect(operation.method)}. Name the resource by " <>
      "#{instead}its path (#{inspect(operation.path)})."
  end

  defp checked(prefix, path, item) do
    case Regex.scan(~r/\{[^}]+\}/, path) do
      [_one] ->
        methods = for m <- @methods, Map.has_key?(item, Atom.to_string(m)), do: m
        {:ok, %{prefix: prefix, path: path, methods: methods}}

      _ ->
        {:error,
         "#{label(prefix)}: the resource path #{path} must have exactly one path parameter, " <>
           "which the id fills."}
    end
  end

  defp label(prefix), do: "`prefixed_ids:` prefix #{prefix}"
end
