defmodule Hearth.Render.Headers do
  @moduledoc false

  # The code `headers:` adds to Layer 1: the `@headers` pairs and a
  # `put_headers/1` request step. Each value resolves per request, like
  # the credential: the request's option (`tenant_id: "…"`), else the
  # client's config; a string, a 0-arity fun or an `{m, f, a}`. A header
  # already on the request is left alone; a missing value raises when the
  # request runs. `[]` renders nothing.

  @spec step([{String.t(), atom()}]) :: String.t()
  def step([]), do: ""

  def step(headers) do
    """


    @headers #{inspect(headers)}

    # Runs after Req's own steps, so a header already on the request wins.
    defp put_headers(request) do
      Enum.reduce(@headers, request, fn {name, key}, request ->
        if Req.Request.get_header(request, name) == [],
          do: Req.Request.put_header(request, name, header_value(request, name, key)),
          else: request
      end)
    end

    defp header_value(request, name, key) do
      case request.options[key] || Application.get_env(@otp_app, __MODULE__, [])[key] do
        value when is_binary(value) ->
          value

        fun when is_function(fun, 0) ->
          fun.()

        {module, function, args} ->
          apply(module, function, args)

        nil ->
          raise "missing \#{inspect(key)} for \#{inspect(__MODULE__)} (the \#{name} header) — " <>
                  "set it in config or pass `\#{key}:` to new/1, request/2 or a behaviour function"
      end
    end\
    """
  end

  # The moduledoc section, indented to sit inside the heredoc.
  @spec doc([{String.t(), atom()}], atom(), module()) :: String.t()
  def doc([], _otp_app, _module), do: ""

  def doc(headers, otp_app, module) do
    lines =
      Enum.map_join(headers, "\n", fn {name, key} -> "  * `#{name}` — `#{inspect(key)}`" end)

    """


    ## Headers

    Every request sends:

    #{lines}

    Each value comes from the option of that name — accepted by `new/1`,
    `request/2` and every function of the behaviour — or else from
    `config #{inspect(otp_app)}, #{inspect(module)}, …`. It may be a
    string, a 0-arity function, or an `{module, function, args}` tuple,
    resolved when each request runs. A header you set on the request
    yourself is left alone.
    """
    |> String.trim_trailing()
    |> String.replace(~r/^(?=.)/m, "  ")
  end
end
