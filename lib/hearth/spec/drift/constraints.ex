defmodule Hearth.Spec.Drift.Constraints do
  @moduledoc false

  # The constraint keywords of one schema node, compared between two
  # versions as `{detail, effect}`. An effect says who a change breaks:
  # `:request` — it accepts less (breaks callers sending data),
  # `:response` — it may return more (breaks code reading it), `:both`,
  # or `:none`. `Drift.Schema` walks the nesting and judges the effect
  # by the schema's side.
  #
  #   * upper bounds (`maxLength`, `maxItems`, `maxProperties`): added or
  #     lowered tightens, removed or raised loosens; lower bounds
  #     (`min…`) the other way round
  #   * `maximum` / `exclusiveMaximum` (and the `minimum` pair) as one
  #     effective bound — the stricter of the two, 3.0 boolean or 3.1
  #     number alike — so `maximum: 10, exclusiveMaximum: true` ≡
  #     `exclusiveMaximum: 10`, and `exclusiveMaximum: 10` →
  #     `maximum: 10` loosens
  #   * `multipleOf`: a multiple of the old one tightens, a divisor
  #     loosens, anything else breaks both
  #   * `pattern`, `format`, `const`, `not`: added tightens, removed
  #     loosens, changed breaks both
  #   * `uniqueItems` set tightens, cleared loosens
  #   * `readOnly` set breaks requests, `writeOnly` set breaks responses;
  #     clearing either breaks nothing
  #   * `default` changed breaks requests — callers omitting the value
  #     get another one; added or removed is drift that breaks nothing
  #     (usually the spec documenting what the server already does)
  #
  # Numbers compare by value, so `1` and `1.0` are the same. Explicit
  # keywords only: anything else is ignored.

  @type effect :: :request | :response | :both | :none

  @upper ~w(maxLength maxItems maxProperties)
  @lower ~w(minLength minItems minProperties)
  @numeric [{"maximum", "exclusiveMaximum", :upper}, {"minimum", "exclusiveMinimum", :lower}]
  @exact ~w(pattern format const)

  @spec changes(map(), map()) :: [{String.t(), effect()}]
  def changes(old, new) do
    Enum.flat_map(@upper, &bound(&1, old[&1], new[&1], :upper)) ++
      Enum.flat_map(@lower, &bound(&1, old[&1], new[&1], :lower)) ++
      Enum.flat_map(@numeric, &numeric(&1, old, new)) ++
      multiple_of(old["multipleOf"], new["multipleOf"]) ++
      Enum.flat_map(@exact, &exact(&1, fetch(old, &1), fetch(new, &1))) ++
      flag("uniqueItems", old, new, {:request, :response}) ++
      flag("readOnly", old, new, {:request, :none}) ++
      flag("writeOnly", old, new, {:response, :none}) ++
      negation(old["not"], new["not"]) ++
      default(fetch(old, "default"), fetch(new, "default"))
  end

  # A value as it reads in a detail line.
  @spec text(term()) :: String.t()
  def text(nil), do: "null"
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def text(value), do: JSON.encode!(value)

  # A value with its whole floats as integers, for exact comparisons.
  @spec normalize(term()) :: term()
  def normalize(value) when is_float(value) and value == trunc(value), do: trunc(value)
  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(%{} = value), do: Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  def normalize(value), do: value

  defp fetch(schema, key) do
    case Map.fetch(schema, key) do
      {:ok, value} -> {:ok, normalize(value)}
      :error -> :error
    end
  end

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

  # `maximum` and `exclusiveMaximum` (or the `minimum` pair) judged
  # together by the bound they make; each changed keyword gets a line.
  defp numeric({base, key, dir}, old, new) do
    changed = for k <- [base, key], old[k] != new[k], do: k

    effect =
      case {effective(old, base, key, dir), effective(new, base, key, dir)} do
        {:invalid, _} -> :both
        {_, :invalid} -> :both
        {old_bound, new_bound} -> compare_bounds(old_bound, new_bound, dir)
      end

    if changed == [] or effect == :none,
      do: [],
      else: for(k <- changed, do: numeric_change(k, old[k], new[k], effect))
  end

  # `nil` (unbounded), `{value, exclusive?}`, or `:invalid`.
  defp effective(schema, base, key, dir) do
    {inclusive, exclusive} = {schema[base], schema[key]}

    cond do
      not (is_nil(inclusive) or is_number(inclusive)) ->
        :invalid

      not (is_nil(exclusive) or is_number(exclusive) or is_boolean(exclusive)) ->
        :invalid

      is_number(exclusive) and is_number(inclusive) ->
        stricter({inclusive, false}, {exclusive, true}, dir)

      is_number(exclusive) ->
        {exclusive, true}

      is_number(inclusive) ->
        {inclusive, exclusive == true}

      true ->
        nil
    end
  end

  defp stricter(a, b, dir), do: if(compare_bounds(a, b, dir) == :request, do: b, else: a)

  defp compare_bounds(same, same, _dir), do: :none
  defp compare_bounds(nil, _new, _dir), do: :request
  defp compare_bounds(_old, nil, _dir), do: :response

  defp compare_bounds({old, old_exclusive}, {new, new_exclusive}, dir) do
    cond do
      old == new and old_exclusive == new_exclusive -> :none
      old == new -> if new_exclusive, do: :request, else: :response
      new < old == (dir == :upper) -> :request
      true -> :response
    end
  end

  # A 3.0 boolean exclusive keyword reads absent as `false`.
  defp numeric_change(key, old, new, effect) when is_boolean(old) or is_boolean(new),
    do: detail(key, to_string(old == true), to_string(new == true), effect)

  defp numeric_change(key, old, new, effect), do: change(key, old, new, effect)

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

  # A quotient too large for a float, or one that underflows to zero, is
  # no multiple worth reporting.
  defp multiple?(a, b) when is_number(a) and is_number(b) and b != 0 do
    quotient = a / b
    round(quotient) != 0 and abs(quotient - round(quotient)) < 1.0e-9
  rescue
    ArithmeticError -> false
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
  defp default(:error, {:ok, new}), do: [detail("default", "(none)", text(new), :none)]
  defp default({:ok, old}, :error), do: [detail("default", text(old), "(none)", :none)]
  defp default({:ok, old}, {:ok, new}), do: [detail("default", text(old), text(new), :request)]

  defp change(key, old, new, effect) do
    show = fn value -> if is_nil(value), do: "(none)", else: text(value) end
    detail(key, show.(old), show.(new), effect)
  end

  defp detail(key, old, new, effect), do: {"#{key} #{old} → #{new}", effect}
end
