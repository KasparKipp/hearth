defmodule Hearth.Config.Types do
  @moduledoc false

  # The custom NimbleOptions types `Hearth.Config.Schema` uses where the
  # built-in ones can't say it: names that become Elixir identifiers or
  # HTTP header names, JSON pointers and values, and where a value comes
  # from (`Hearth.Spec.Values`). Each returns the value unchanged; the
  # modules that read the entry normalize it. Pure.

  alias Hearth.Spec.PrefixedIds

  @option_schema [option: [type: {:custom, __MODULE__, :identifier, []}, required: true]]
  @resolve_schema [
    resolve: [
      type:
        {:tuple,
         [{:custom, __MODULE__, :module_alias, []}, {:custom, __MODULE__, :identifier, []}]},
      required: true
    ],
    options: [type: {:list, {:custom, __MODULE__, :identifier, []}}]
  ]

  # An atom that reads as a function or variable name: `:app_key`.
  def identifier(atom) when is_atom(atom) and atom not in [nil, true, false] do
    if Regex.match?(~r/^[a-z_][a-z0-9_]*$/, Atom.to_string(atom)),
      do: {:ok, atom},
      else: {:error, "expected a snake_case name, got: #{inspect(atom)}"}
  end

  def identifier(other), do: {:error, "expected a snake_case name, got: #{inspect(other)}"}

  def module_alias(module) when is_atom(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir."),
      do: {:ok, module},
      else: {:error, "expected a module alias, got: #{inspect(module)}"}
  end

  def module_alias(other), do: {:error, "expected a module alias, got: #{inspect(other)}"}

  # Where a value comes from: a config key, `[option: key]`, or
  # `[resolve: {M, :f}, options: [...]]`.
  def value(key) when is_atom(key) do
    with {:error, _} <- identifier(key), do: {:error, value_message(key, nil)}
  end

  def value([_ | _] = form) do
    schema = if Keyword.has_key?(form, :resolve), do: @resolve_schema, else: @option_schema

    with true <- Keyword.keyword?(form),
         {:ok, _opts} <- NimbleOptions.validate(form, schema) do
      {:ok, form}
    else
      {:error, error} -> {:error, value_message(form, error.message)}
      false -> {:error, value_message(form, nil)}
    end
  end

  def value(other), do: {:error, value_message(other, nil)}

  defp value_message(value, detail) do
    "expected a config key (`:app_key`), `[option: :app_key]` or " <>
      "`[resolve: {MyApp.Module, :function}, options: [...]]`, got: #{inspect(value)}" <>
      if(detail, do: " (#{Hearth.Config.Schema.strip(detail)})", else: "")
  end

  # `headers:` — HTTP header names (any case) to value forms.
  def headers(headers) do
    with true <- Keyword.keyword?(headers) || {:error, "expected a keyword list"},
         nil <- Enum.find_value(headers, &header_error/1) do
      {:ok, headers}
    end
  end

  defp header_error({header, form}) do
    name = header |> Atom.to_string() |> String.downcase()

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9!#$%&'*+.^_`|~-]*$/, name) ->
        {:error, "#{inspect(name)} isn't an HTTP header name"}

      match?({:error, _}, value(form)) ->
        {:error, value(form) |> elem(1) |> then(&"#{inspect(name)}: #{&1}")}

      true ->
        nil
    end
  end

  # `prefixed_ids: [functions:]` — function names to HTTP methods.
  def functions([_ | _] = functions) do
    if Keyword.keyword?(functions) and
         Enum.all?(functions, fn {name, method} ->
           match?({:ok, _}, identifier(name)) and method in PrefixedIds.methods()
         end),
       do: {:ok, functions},
       else: {:error, functions_message(functions)}
  end

  def functions(other), do: {:error, functions_message(other)}

  defp functions_message(value) do
    "expected snake_case function names mapped to " <>
      "#{Enum.map_join(PrefixedIds.methods(), ", ", &inspect/1)}, got: #{inspect(value)}"
  end

  def registry_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.\-]*$/, name),
      do: {:ok, name},
      else:
        {:error,
         "expected a shortcut name (letters, digits, `_`, `.`, `-`), got: #{inspect(name)}"}
  end

  def registry_name(other), do: {:error, "expected a string, got: #{inspect(other)}"}

  # A registry version's location — a URL or file path — or
  # `{:alias, version}`.
  def version(location) when is_binary(location), do: {:ok, location}
  def version({:alias, target} = version) when is_binary(target), do: {:ok, version}

  def version(other),
    do: {:error, ~s|expected a URL, a file path or {:alias, "version"}, got: #{inspect(other)}|}

  # A JSON pointer below the document root: `"/components/…"`.
  def json_pointer("/" <> _ = pointer), do: {:ok, pointer}

  def json_pointer(other),
    do: {:error, ~s|#{inspect(other)} isn't a JSON pointer — it starts with "/"|}

  # A JSON value: string keys, no atoms beyond true / false / nil.
  def json(value) do
    if json?(value),
      do: {:ok, value},
      else: {:error, "expected a JSON value (string keys, no atoms beyond true / false / nil)"}
  end

  defp json?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json?(nil), do: true
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)

  defp json?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json?(value) end)

  defp json?(_value), do: false

  # `overrides: [shared:]` — a component as `"section/name"`.
  def component(component) when is_binary(component) do
    case String.split(component, "/", parts: 2) do
      [section, name] when section != "" and name != "" -> {:ok, component}
      _ -> {:error, ~s|expected "section/name", got: #{inspect(component)}|}
    end
  end

  def component(other), do: {:error, ~s|expected "section/name", got: #{inspect(other)}|}
end
