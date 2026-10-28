defmodule Hearth.Spec.Values do
  @moduledoc false

  # Where Layer 1 gets the values that vary by environment or by call:
  # the credential (`auth: [credential: …]`), each `headers:` value, and
  # the base URL (`base_url: …`). Each takes one of three forms, and the
  # request option always comes first:
  #
  #   * `key` — the `key` option, else `config … key:`; gen wires
  #     `<INT>_<KEY>` into runtime.exs. Today's behaviour, and the
  #     default credential (`:api_key`);
  #   * `[option: key]` — the `key` option only; never read from config;
  #   * `[resolve: {M, :f}, options: [k, …]]` — `M.f([k: …])` when each
  #     request runs, given the listed request options. The credential
  #     and the base URL still take their option first (`:api_key`,
  #     `:base_url`); a header has none — one set on the request wins.
  #
  # Each form becomes `{:config, key}`, `{:option, key}` or
  # `{:resolve, {m, f}, keys}`. An absent `base_url:` is nil: the config
  # `base_url:`, else the spec's, with nothing wired.
  #
  # Pure. `Hearth.Config.Schema` checks each form's shape
  # (`Hearth.Config.Types.value/1`); the checks across values (shared
  # keys, keys Req already uses) are here.

  @type t :: {:config, atom()} | {:option, atom()} | {:resolve, {module(), atom()}, [atom()]}
  @type values :: %{credential: t(), headers: [{String.t(), t()}], base_url: t() | nil}

  # Names Req or Layer 1 already use as request options (Req 0.7's
  # registered options plus `Req.new/1`'s own) — a per-call
  # `tenant_id: …` travels through the same keyword.
  @reserved ~w(
    method url headers body into adapter options
    auth aws_sigv4 base_url cache cache_dir checksum compress_body compressed
    connect_options decode_body decode_json decoders finch finch_private finch_request
    follow_redirects form form_multipart http_errors inet6 json location_trusted
    max_redirects max_retries params path_params path_params_style plug
    pool_max_idle_time pool_timeout range raw receive_timeout redact_auth redirect
    redirect_log_level redirect_trusted request_timeout retry retry_delay
    retry_log_level unix_socket user_agent
  )a

  # Without any of the keys: the `:api_key` option or config, no headers,
  # the spec's base URL.
  @spec default() :: values()
  def default, do: %{credential: {:config, :api_key}, headers: [], base_url: nil}

  # `Hearth.Config.Schema` has checked the entry — its shape, and
  # `check/1` when the file was read.
  @spec parse(keyword()) :: values()
  def parse(entry),
    do: %{credential: credential(entry), headers: headers(entry), base_url: base_url(entry)}

  # The checks across an entry's values: no key shared between them, none
  # Req already uses, `:base_url` for the base URL.
  @spec check(keyword()) :: :ok | {:error, String.t()}
  def check(entry), do: conflicts(parse(entry))

  # The request options `new/1` registers: the credential's (when the
  # auth scheme takes one), each header's, the resolvers'. `:base_url`
  # is Req's own.
  @spec options(values(), boolean()) :: [atom()]
  def options(values, keyed?) do
    credential = if keyed?, do: credential_options(values.credential), else: []

    (credential ++
       Enum.flat_map(values.headers, fn {_name, value} -> own_options(value) end) ++
       if(values.base_url, do: own_options(values.base_url), else: []))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == :base_url))
  end

  defp credential_options({:resolve, _mf, keys}), do: [:api_key | keys]
  defp credential_options(value), do: own_options(value)

  defp own_options({:resolve, _mf, keys}), do: keys
  defp own_options({_form, key}), do: [key]

  # The config keys gen wires into runtime.exs: the bare ones.
  @spec config_keys(values(), boolean()) :: [atom()]
  def config_keys(values, keyed?) do
    credential = if keyed?, do: [values.credential], else: []

    (credential ++ Enum.map(values.headers, &elem(&1, 1)) ++ [values.base_url])
    |> Enum.flat_map(fn
      {:config, key} -> [key]
      _ -> []
    end)
  end

  defp credential(entry) do
    case entry[:auth] do
      auth when is_list(auth) -> form(Keyword.get(auth, :credential, :api_key))
      nil -> {:config, :api_key}
    end
  end

  defp base_url(entry) do
    case Keyword.fetch(entry, :base_url) do
      :error -> nil
      {:ok, form} -> form(form)
    end
  end

  defp headers(entry) do
    for {header, form} <- Keyword.get(entry, :headers, []),
        do: {header |> Atom.to_string() |> String.downcase(), form(form)}
  end

  defp form(key) when is_atom(key), do: {:config, key}

  defp form(form) do
    case Keyword.fetch(form, :resolve) do
      {:ok, mf} -> {:resolve, mf, Keyword.get(form, :options, [])}
      :error -> {:option, Keyword.fetch!(form, :option)}
    end
  end

  # Every key a value owns — its config or option key, `:api_key` for a
  # resolved credential — belongs to that value alone. Resolver
  # `options:` may be shared: they only read what the call passes.
  defp conflicts(values) do
    owned =
      [{"`credential:`", values.credential}] ++
        Enum.map(values.headers, fn {name, value} -> {"`headers:` #{inspect(name)}", value} end) ++
        if(values.base_url, do: [{"`base_url:`", values.base_url}], else: [])

    with :ok <- check_base_url(values.base_url),
         :ok <- check_reserved(owned) do
      check_shared(owned)
    end
  end

  defp check_base_url({form, key}) when form in [:config, :option] and key != :base_url,
    do:
      {:error, "`base_url:` reads Req's own `:base_url` option, so its key must be `:base_url`."}

  defp check_base_url(_value), do: :ok

  defp check_reserved(owned) do
    Enum.find_value(owned, :ok, fn {label, value} ->
      keys = if label == "`base_url:`", do: resolver_keys(value), else: keys(value)

      case Enum.filter(keys, &(&1 in @reserved)) do
        [] ->
          nil

        reserved ->
          {:error,
           "#{label} uses #{Enum.map_join(reserved, ", ", &inspect/1)}, which is already a " <>
             "request option; pick another key."}
      end
    end)
  end

  defp keys({:resolve, _mf, keys}), do: keys
  defp keys({_form, key}), do: [key]

  defp resolver_keys({:resolve, _mf, keys}), do: keys
  defp resolver_keys(_value), do: []

  defp check_shared(owned) do
    owned
    |> Enum.flat_map(fn {label, value} -> Enum.map(owned_keys(label, value), &{&1, label}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find_value(:ok, fn
      {key, [first, second | _]} ->
        {:error, "#{first} and #{second} use the same key #{inspect(key)}; give each its own."}

      _ ->
        nil
    end)
  end

  defp owned_keys("`credential:`", {:resolve, _mf, _keys}), do: [:api_key]
  defp owned_keys(_label, {:resolve, _mf, _keys}), do: []
  defp owned_keys(_label, {_form, key}), do: [key]
end
