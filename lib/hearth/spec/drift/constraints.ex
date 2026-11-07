defmodule Hearth.Spec.Drift.Constraints do
  @moduledoc false

  # The constraint keywords of one schema node, compared between two
  # versions as `{detail, effect}`. An effect says who a change breaks:
  # `:request` — it accepts less (breaks callers sending data),
  # `:response` — it may return more (breaks code reading it), `:both`,
  # or `:none`. `Drift.Schema` walks the nesting and judges the effect
  # by the schema's side.
  #
  #   * upper bounds (`maxLength`, `maxItems`, `maxProperties`,
  #     `maximum`): added or lowered tightens, removed or raised loosens;
  #     lower bounds (`min…`) the other way round
  #   * `exclusiveMaximum` / `exclusiveMinimum`: 3.0 booleans tighten
  #     when set; 3.1 numbers compare like bounds. A 3.0 pair rewritten in
  #     3.1 form (`maximum: 10, exclusiveMaximum: true` ≡
  #     `exclusiveMaximum: 10`) is no change
  #   * `multipleOf`: a multiple of the old one tightens, a divisor
  #     loosens, anything else breaks both
  #   * `pattern`, `format`, `const`, `not`: added tightens, removed
  #     loosens, changed breaks both
  #   * `uniqueItems` set tightens, cleared loosens
  #   * `readOnly` set breaks requests, `writeOnly` set breaks responses;
  #     clearing either breaks nothing
  #   * `default` changed breaks requests — callers omitting the value
  #     get another one
  #
  # Explicit keywords only: anything else is ignored.

  @type effect :: :request | :response | :both | :none

  @upper ~w(maxLength maxItems maxProperties maximum)
  @lower ~w(minLength minItems minProperties minimum)
  @exclusive [{"exclusiveMaximum", "maximum", :upper}, {"exclusiveMinimum", "minimum", :lower}]
  @exact ~w(pattern format const)

  @spec changes(map(), map()) :: [{String.t(), effect()}]
  def changes(old, new) do
    {old, new} = exclusive_forms(old, new)

    Enum.flat_map(@upper, &bound(&1, old[&1], new[&1], :upper)) ++
      Enum.flat_map(@lower, &bound(&1, old[&1], new[&1], :lower)) ++
      Enum.flat_map(@exclusive, fn {key, _base, dir} ->
        exclusive(key, old[key], new[key], dir)
      end) ++
      multiple_of(old["multipleOf"], new["multipleOf"]) ++
      Enum.flat_map(@exact, &exact(&1, Map.fetch(old, &1), Map.fetch(new, &1))) ++
      flag("uniqueItems", old, new, {:request, :response}) ++
      flag("readOnly", old, new, {:request, :none}) ++
      flag("writeOnly", old, new, {:response, :none}) ++
      negation(old["not"], new["not"]) ++
      default(Map.fetch(old, "default"), Map.fetch(new, "default"))
  end

  # A value as it reads in a detail line.
  @spec text(term()) :: String.t()
  def text(nil), do: "null"
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def text(value), do: JSON.encode!(value)

  defp bound(key, old, new, dir) do
    cond do
      old == new -> []
      is_nil(old) -> [change(key, old, new, :request)]
      is_nil(new) -> [change(key, old, new, :response)]
      not (is_number(old) and is_number(new)) -> [change(key, old, new, :both)]
      new < old == (dir == :upper) -> [change(key, old, new, :request)]
      true -> [change(key, old, new, :response)]
    end
  end

  defp exclusive(key, old, new, dir) do
    if is_boolean(old) or is_boolean(new),
      do: flag(key, %{key => old}, %{key => new}, {:request, :response}),
      else: bound(key, old, new, dir)
  end

  # When one side has a 3.0 boolean exclusive bound and the other a 3.1
  # number, the boolean side is rewritten in 3.1 form.
  defp exclusive_forms(old, new) do
    Enum.reduce(@exclusive, {old, new}, fn {key, base, _dir}, {old, new} ->
      cond do
        is_boolean(old[key]) and is_number(new[key]) -> {numeric(old, key, base), new}
        is_number(old[key]) and is_boolean(new[key]) -> {old, numeric(new, key, base)}
        true -> {old, new}
      end
    end)
  end

  defp numeric(schema, key, base) do
    if schema[key] == true and is_number(schema[base]),
      do: schema |> Map.delete(base) |> Map.put(key, schema[base]),
      else: Map.delete(schema, key)
  end

  defp multiple_of(old, new) do
    cond do
      old == new -> []
      is_nil(old) -> [change("multipleOf", old, new, :request)]
      is_nil(new) -> [change("multipleOf", old, new, :response)]
      multiple?(new, old) -> [change("multipleOf", old, new, :request)]
      multiple?(old, new) -> [change("multipleOf", old, new, :response)]
      true -> [change("multipleOf", old, new, :both)]
    end
  end

  defp multiple?(a, b) when is_number(a) and is_number(b) and b != 0 do
    quotient = a / b
    abs(quotient - round(quotient)) < 1.0e-9
  end

  defp multiple?(_a, _b), do: false

  defp exact(_key, same, same), do: []
  defp exact(key, :error, {:ok, new}), do: [detail(key, "(none)", text(new), :request)]
  defp exact(key, {:ok, old}, :error), do: [detail(key, text(old), "(none)", :response)]
  defp exact(key, {:ok, old}, {:ok, new}), do: [detail(key, text(old), text(new), :both)]

  # A boolean keyword; absent reads as false. `{set, cleared}` effects.
  defp flag(key, old, new, {set, cleared}) do
    case {old[key] == true, new[key] == true} do
      {same, same} -> []
      {false, true} -> [detail(key, "false", "true", set)]
      {true, false} -> [detail(key, "true", "false", cleared)]
    end
  end

  defp negation(same, same), do: []
  defp negation(nil, _new), do: [detail("not", "(none)", "schema", :request)]
  defp negation(_old, nil), do: [detail("not", "schema", "(none)", :response)]
  defp negation(_old, _new), do: [{"not schema changed", :both}]

  defp default(same, same), do: []
  defp default(old, new), do: [detail("default", shown(old), shown(new), :request)]

  defp shown(:error), do: "(none)"
  defp shown({:ok, value}), do: text(value)

  defp change(key, old, new, effect) do
    show = fn value -> if is_nil(value), do: "(none)", else: text(value) end
    detail(key, show.(old), show.(new), effect)
  end

  defp detail(key, old, new, effect), do: {"#{key} #{old} → #{new}", effect}
end
