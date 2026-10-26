defmodule Hearth.Render.Values do
  @moduledoc false

  # The Layer 1 code that looks up a `Hearth.Spec.Values` value when a
  # request runs. Each lookup is rendered inline, so the code says where
  # each value comes from — and an `[option:]` or `[resolve:]` value
  # never reaches `Application.get_env`:
  #
  #   * `{:config, key}`  — the `key` option, else `config … key:`; a
  #     string, a 0-arity fun or an `{m, f, a}`;
  #   * `{:option, key}`  — the `key` option, else raise;
  #   * `{:resolve, …}`   — the override option first, if the value has
  #     one (`:api_key` for the credential), else the resolver, given the
  #     listed request options; anything but a string raises.
  #
  # `helpers/1` renders `resolver_options/2` and `resolved!/2`, once,
  # when some value is resolved.

  alias Hearth.Spec.Values

  # `var` names the matched value (`key` for the credential, as it always
  # was); `what` follows the module in the error (` (the x-app-key header)`).
  @spec lookup(Values.t(), keyword()) :: String.t()
  def lookup({:config, key}, opts) do
    {var, what} = {opts[:var] || "value", opts[:what] || ""}

    """
    case request.options[#{inspect(key)}] || Application.get_env(@otp_app, __MODULE__, [])[#{inspect(key)}] do
      #{var} when is_binary(#{var}) -> #{var}
      fun when is_function(fun, 0) -> fun.()
      {module, function, args} -> apply(module, function, args)
      nil ->
        raise "missing #{inspect(key)} for \#{inspect(__MODULE__)}#{what} — set it in config " <>
                "or pass `#{key}:` to new/1, request/2 or a behaviour function"
    end
    """
  end

  def lookup({:option, key}, opts) do
    {var, what} = {opts[:var] || "value", opts[:what] || ""}

    """
    case request.options[#{inspect(key)}] do
      #{var} when is_binary(#{var}) -> #{var}
      fun when is_function(fun, 0) -> fun.()
      {module, function, args} -> apply(module, function, args)
      nil ->
        raise "missing #{inspect(key)} for \#{inspect(__MODULE__)}#{what} — " <>
                "pass `#{key}:` to new/1, request/2 or a behaviour function"
    end
    """
  end

  def lookup({:resolve, _mf, _keys} = value, opts) do
    var = opts[:var] || "value"
    resolved = resolve_call(value, opts[:what] || "")

    case opts[:override] do
      nil ->
        resolved <> "\n"

      key ->
        """
        case request.options[#{inspect(key)}] do
          nil -> #{resolved}
          #{var} when is_binary(#{var}) -> #{var}
          fun when is_function(fun, 0) -> fun.()
          {module, function, args} -> apply(module, function, args)
        end
        """
    end
  end

  # `M.f([k: …])`, its result checked.
  @spec resolve_call(Values.t(), String.t()) :: String.t()
  def resolve_call({:resolve, {module, function}, keys}, what) do
    label = "#{inspect(module)}.#{function}/1#{what}"

    ~s|resolved!(#{inspect(module)}.#{function}(resolver_options(request, #{inspect(keys)})), #{inspect(label)})|
  end

  @spec helpers([Values.t() | nil]) :: String.t()
  def helpers(values) do
    if Enum.any?(values, &match?({:resolve, _, _}, &1)) do
      """


      # The request options a resolver is given.
      defp resolver_options(request, keys), do: request.options |> Map.take(keys) |> Map.to_list()

      # A resolver must return a string. The value isn't shown, in case
      # it's a secret.
      defp resolved!(value, _resolver) when is_binary(value), do: value

      defp resolved!(_value, resolver),
        do: raise("\#{resolver} returned no string for \#{inspect(__MODULE__)}")\
      """
    else
      ""
    end
  end

  # One line per value for a moduledoc list: where it comes from.
  @spec source(Values.t()) :: String.t()
  def source({:config, key}), do: "the `#{inspect(key)}` option, else config"
  def source({:option, key}), do: "the `#{inspect(key)}` option"

  def source({:resolve, {module, function}, keys}),
    do: "`#{inspect(module)}.#{function}/1`#{given(keys)}"

  @spec given([atom()]) :: String.t()
  def given([]), do: ""
  def given(keys), do: ", given " <> Enum.map_join(keys, ", ", &"`#{inspect(&1)}`")
end
