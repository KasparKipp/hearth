defmodule Hearth.Render.Headers do
  @moduledoc false

  # The code `headers:` adds to Layer 1: the `@headers` names, a
  # `put_headers/1` request step, and a `header_value/2` clause per
  # header that looks its value up the way the entry says
  # (`Hearth.Render.Values`): the request option, else config; the
  # option only; or a resolver. A header already on the request is left
  # alone; a missing value raises when the request runs. `[]` renders
  # nothing.

  alias Hearth.Render.Values

  @spec step([{String.t(), Hearth.Spec.Values.t()}]) :: String.t()
  def step([]), do: ""

  def step(headers) do
    clauses = Enum.map_join(headers, "\n", &clause/1)

    """


    @headers #{inspect(Enum.map(headers, &elem(&1, 0)))}

    # Runs after Req's own steps, so a header already on the request wins.
    defp put_headers(request) do
      Enum.reduce(@headers, request, fn name, request ->
        if Req.Request.get_header(request, name) == [],
          do: Req.Request.put_header(request, name, header_value(request, name)),
          else: request
      end)
    end

    #{clauses}\
    """
  end

  defp clause({name, value}) do
    """
    # #{name}: #{Values.source(value)}.
    defp header_value(request, #{inspect(name)}) do
      #{Values.lookup(value, what: " (the #{name} header)")}
    end
    """
  end

  # The moduledoc section, indented to sit inside the heredoc.
  @spec doc([{String.t(), Hearth.Spec.Values.t()}], atom(), module()) :: String.t()
  def doc([], _otp_app, _module), do: ""

  def doc(headers, otp_app, module) do
    lines =
      Enum.map_join(headers, "\n", fn {name, value} ->
        "  * `#{name}` — #{Values.source(value)}"
      end)

    """


    ## Headers

    Every request sends:

    #{lines}

    An option is accepted by `new/1`, `request/2` and every function of
    the behaviour. Config means `config #{inspect(otp_app)}, #{inspect(module)}, …`.
    An option or config value may be a string, a 0-arity function, or an
    `{module, function, args}` tuple; a resolver must return a string.
    Each is resolved when the request runs. A header you set on the
    request yourself is left alone.
    """
    |> String.trim_trailing()
    |> String.replace(~r/^(?=.)/m, "  ")
  end
end
