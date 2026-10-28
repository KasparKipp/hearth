defmodule Hearth.Config.Schema do
  @moduledoc false

  # The shape of `.hearth.exs`, in one place: a NimbleOptions schema the
  # whole file is validated against when it's read (`Hearth.Config.load/1`).
  # Shape — types, the keys each level allows, required keys — plus the
  # checks across an entry's values (`Hearth.Spec.Values.check/1`). What
  # needs the spec (a `scheme:` it has, a prefix target that resolves, a
  # rename that doesn't collide) stays with the module that reads the
  # key. Errors name the entry and the key, and carry an example where
  # one helps. Pure.

  alias Hearth.Config.Types
  alias Hearth.Spec.Values

  @state {:or,
          [
            {:in, [:all, :none]},
            {:keyword_list,
             include: [type: {:list, :string}, required: true],
             exclude: [type: {:list, :string}, required: true]}
          ]}

  @value {:custom, Types, :value, []}

  @entry [
    module: [type: {:custom, Types, :module_alias, []}],
    source: [type: :string],
    sources: [type: :non_empty_keyword_list, keys: [*: [type: :string]]],
    source_sha256: [type: {:or, [:string, {:keyword_list, [*: [type: :string]]}]}],
    base_path: [type: :string],
    tags: [type: :keyword_list, keys: [*: [type: @state]]],
    untagged: [type: @state],
    overrides: [
      type: :keyword_list,
      keys: [
        patches: [
          type: {:map, {:custom, Types, :json_pointer, []}, {:custom, Types, :json, []}}
        ],
        tags: [type: :keyword_list, keys: [*: [type: {:list, :string}]]],
        operation_ids: [type: {:map, :string, :string}],
        shared: [type: {:map, {:custom, Types, :component, []}, :atom}]
      ]
    ],
    auth: [
      type: :keyword_list,
      keys: [
        scheme: [type: {:or, [:string, nil]}],
        available: [type: :keyword_list, keys: [*: [type: :string]]],
        credential: [type: @value]
      ]
    ],
    headers: [type: {:custom, Types, :headers, []}],
    base_url: [type: @value],
    prefixed_ids: [
      type: :non_empty_keyword_list,
      keys: [
        functions: [type: {:custom, Types, :functions, []}],
        prefixes: [
          type: :non_empty_keyword_list,
          required: true,
          keys: [*: [type: :string]]
        ]
      ]
    ]
  ]

  @schema [
    integrations: [type: :keyword_list, keys: [*: [type: :keyword_list, keys: @entry]]],
    registry: [
      type:
        {:map, {:custom, Types, :registry_name, []},
         {:map, :string, {:custom, Types, :version, []}}}
    ]
  ]

  # What a key holds, said once, for the error messages. Looked up by
  # the key's path within the entry (or the file, for top-level keys);
  # the longest matching prefix wins.
  @file_hints %{
    [:integrations] =>
      "It's a keyword list of keyword lists, e.g. " <>
        "`[integrations: [stripe: [module: MyApp.Integrations.Stripe]]]`.",
    [:registry] =>
      "It maps a name to %{version => URL or file path}, e.g. " <>
        ~s|`registry: %{"acme_api" => %{"1.3" => "https://…/openapi.json", "latest" => {:alias, "1.3"}}}`.|
  }

  @entry_hints %{
    [:module] =>
      "It names the integration's Layer 1 module, e.g. `module: MyApp.Integrations.Stripe`.",
    [:sources] =>
      "It maps a short name per spec to its source, e.g. " <>
        ~s|`sources: [items: "priv/specs/items.json", orders: "priv/specs/orders.json"]`.|,
    [:tags] =>
      "Each tag is `:all`, `:none`, or `[include: [...], exclude: [...]]` lists of operationIds.",
    [:untagged] =>
      "It's `:all`, `:none`, or `[include: [...], exclude: [...]]` lists of operationIds.",
    [:overrides] =>
      ~s|It's a keyword list, e.g. `overrides: [tags: [Customers: ["/v1/customers*"]]]`.|,
    [:overrides, :patches] =>
      "It maps JSON pointers to values, e.g. " <>
        ~s|`patches: %{"/security" => [%{"bearerAuth" => []}]}`. Values are JSON: | <>
        "maps with string keys, lists, strings, numbers, true, false and nil.",
    [:overrides, :tags] =>
      ~s|It maps tag names to lists of path globs, "method /path" globs or operationIds, | <>
        ~s|e.g. `tags: [Customers: ["/v1/customers*"]]`.|,
    [:overrides, :operation_ids] =>
      ~s|It maps upstream operationIds (or "method /path") to new ones, | <>
        ~s|e.g. `operation_ids: %{"GetCustomersCustomer" => "GetCustomer"}`.|,
    [:overrides, :shared] =>
      ~s|It maps a component ("section/name") to the source that keeps its name, | <>
        ~s|e.g. `shared: %{"schemas/address" => :items}`.|,
    [:source_sha256] =>
      "gen writes it: the source's checksum, or one per source (`[items: \"…\"]`) " <>
        "for `sources:`. Delete it rather than edit it; gen and `--sync` write it again.",
    [:auth] => ~s|e.g. `auth: [scheme: "bearerAuth", credential: :api_key]`.|,
    [:auth, :scheme] =>
      ~s|It names one of the spec's security schemes as a string, e.g. `scheme: "bearerAuth"`.|,
    [:base_url] =>
      "It says where the base URL comes from, not the URL itself: `base_url: :base_url` " <>
        "reads `config … base_url:`, which gen wires to an env var in runtime.exs.",
    [:headers] =>
      "It maps header names to where their values come from, " <>
        ~s|e.g. `headers: ["x-app-key": :app_key, "x-tenant-id": [option: :tenant_id]]`.|,
    [:prefixed_ids] =>
      "It's a keyword list with `prefixes:` (and optionally `functions:`), " <>
        ~s|e.g. `prefixed_ids: [functions: [retrieve: :get], prefixes: [cus: "GetCustomersCustomer"]]`.|,
    [:prefixed_ids, :functions] =>
      "It maps function names to HTTP methods, e.g. `functions: [retrieve: :get, update: :post]`.",
    [:prefixed_ids, :prefixes] =>
      "It maps each id prefix to an operationId or a path, " <>
        ~s|e.g. `prefixes: [cus: "GetCustomersCustomer"]`.|
  }

  @path ".hearth.exs"

  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(term) do
    case NimbleOptions.validate(term, @schema) do
      {:ok, _validated} -> check_values(Keyword.get(term, :integrations, []))
      {:error, error} -> {:error, message(error)}
    end
  end

  defp check_values(integrations) do
    Enum.find_value(integrations, :ok, fn {key, entry} ->
      case Values.check(entry) do
        :ok -> nil
        {:error, detail} -> {:error, "#{@path}: #{where([:integrations, key])} — #{detail}"}
      end
    end)
  end

  # NimbleOptions reports a key given twice as unknown too.
  defp message(%NimbleOptions.ValidationError{key: keys, keys_path: path})
       when is_list(keys) do
    supported = keys_at(@schema, path)

    case Enum.split_with(keys, &(&1 in supported)) do
      {[], unknown} ->
        "#{@path}: #{where(path)} has unknown #{keys_label(unknown)} — " <>
          "supported: #{keys_label(supported)}."

      {repeated, _unknown} ->
        "#{@path}: #{where(path)} gives #{keys_label(repeated)} more than once — keep one."
    end
  end

  defp message(%NimbleOptions.ValidationError{key: key, keys_path: path} = error) do
    path = path ++ [key]
    hint = hint(path)

    "#{@path}: #{where(path)} — #{detail(error)}." <> if(hint, do: "\n#{hint}", else: "")
  end

  defp where([]), do: "the file"
  defp where([:integrations, name]), do: "the entry for #{name}"
  defp where([:integrations, name | rest]), do: "#{label(rest)} for #{name}"
  defp where(path), do: label(path)

  # `[:module]` → "`module:`"; `[:prefixed_ids, :prefixes]` →
  # "`prefixed_ids: [prefixes: …]`".
  defp label([key]), do: "`#{key_text(key)}`"
  defp label(path), do: "`#{nest(path)}`"

  defp nest([key]), do: "#{key_text(key)} …"
  defp nest([key | rest]), do: "#{key_text(key)} [#{nest(rest)}]"

  defp key_text(key), do: Macro.inspect_atom(:key, key)

  defp keys_label(keys), do: Enum.map_join(keys, ", ", &"`#{key_text(&1)}`")

  defp hint([:integrations, _name | rest]) when rest != [], do: longest(@entry_hints, rest)
  defp hint(path), do: longest(@file_hints, path)

  defp longest(hints, path) do
    Enum.find_value(length(path)..1//-1, fn n -> hints[Enum.take(path, n)] end)
  end

  # NimbleOptions' message, without the "invalid value for :key option:"
  # the label already says.
  defp detail(%NimbleOptions.ValidationError{message: message, value: value}) do
    cond do
      message =~ "to match at least one given type" -> "got: #{inspect(value)}"
      message =~ ~r/^required :\S+ option not found/ -> "is required"
      true -> strip(message)
    end
  end

  # Also turns nested map errors' "invalid map in map key "x": invalid
  # value for map key "1": …" into `"x" "1": …`.
  @spec strip(String.t()) :: String.t()
  def strip(message) do
    message = String.replace(message, ~r/^invalid (value for|map in) :?"?[^ ]+"? option: /, "")
    chain = ~r/^(?:invalid (?:map in|value for) map key(?: ("[^"]*"))?: )+/

    case Regex.run(chain, message) do
      [prefix | _] ->
        keys = Regex.scan(~r/map key ("[^"]*")/, prefix, capture: :all_but_first)
        rest = String.replace_prefix(message, prefix, "")
        if keys == [], do: rest, else: "#{Enum.join(List.flatten(keys), " ")}: #{rest}"

      nil ->
        message
    end
  end

  # The keys the schema allows at `path` — `*` levels match any key.
  defp keys_at(schema, []), do: Keyword.keys(schema) -- [:*]

  defp keys_at(schema, [key | rest]) do
    spec = Keyword.get(schema, key) || Keyword.fetch!(schema, :*)
    keys_at(spec[:keys], rest)
  end
end
