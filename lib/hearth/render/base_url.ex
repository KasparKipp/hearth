defmodule Hearth.Render.BaseUrl do
  @moduledoc false

  # Layer 1's base URL, from the entry's `base_url:` (a
  # `Hearth.Spec.Values` value, or nil):
  #
  #   * nil or `:base_url` — `config … base_url:`, else the `@base_url`
  #     compiled from the spec; gen wires `<INT>_BASE_URL` for the bare
  #     key. Lets `config/test.exs` point the external test at a
  #     non-prod server;
  #   * `[option: :base_url]` / `[resolve: …]` — no `@base_url`; a step
  #     prepended to `new/1` (before Req's `put_base_url`) keeps a
  #     `base_url:` passed per call, else raises / asks the resolver.
  #
  # A path prefix shared by every operation (e.g. `/v3`) is folded into
  # `@base_url` — onto the real URL when the spec declares one, onto the
  # placeholder when it does not, so the prefix is never lost. A resolver
  # or a per-call value gives the whole base URL, as config does.

  alias Hearth.Render.Values

  # Whether `new/1` prepends `resolve_base_url/1`.
  @spec step?(Hearth.Spec.Values.t() | nil) :: boolean()
  def step?({form, _key}) when form == :option, do: true
  def step?({:resolve, _mf, _keys}), do: true
  def step?(_from), do: false

  @spec attr(String.t() | nil, String.t(), Hearth.Spec.Values.t() | nil) :: String.t()
  def attr(url, prefix, from) do
    cond do
      step?(from) -> ""
      url == nil -> placeholder(prefix)
      true -> ~s(@base_url #{inspect(append_prefix(url, prefix))})
    end
  end

  defp placeholder(prefix) do
    ~s(# TODO: the spec declared no `servers` — set the API base URL.\n) <>
      ~s(  @base_url "https://api.example.com#{prefix}")
  end

  defp append_prefix(url, ""), do: url
  defp append_prefix(url, prefix), do: String.trim_trailing(url, "/") <> prefix

  @spec helper(Hearth.Spec.Values.t() | nil) :: String.t()
  def helper(nil), do: helper({:config, :base_url})

  def helper({:config, :base_url}) do
    """

    defp base_url, do: Application.get_env(@otp_app, __MODULE__, [])[:base_url] || @base_url
    """
  end

  def helper({:option, :base_url}) do
    """

    # Runs before Req's own steps; a `base_url:` passed per call is used as is.
    defp resolve_base_url(request) do
      if request.options[:base_url],
        do: request,
        else:
          raise "missing :base_url for \#{inspect(__MODULE__)} — " <>
                  "pass `base_url:` to new/1, request/2 or a behaviour function"
    end
    """
  end

  def helper({:resolve, _mf, _keys} = from) do
    """

    # Runs before Req's own steps; a `base_url:` passed per call wins.
    defp resolve_base_url(request) do
      if request.options[:base_url],
        do: request,
        else: Req.Request.put_option(request, :base_url, #{Values.resolve_call(from, " (the base URL)")})
    end
    """
  end

  # The moduledoc's first paragraph says where the base URL comes from.
  @spec intro(Hearth.Spec.Values.t() | nil) :: String.t()
  def intro(from) when from in [nil, {:config, :base_url}], do: "base URL from the OpenAPI spec"
  def intro(from), do: "base URL from #{Values.source(from)}"

  # The moduledoc section, indented to sit inside the heredoc; none
  # without `base_url:`.
  @spec doc(Hearth.Spec.Values.t() | nil) :: String.t()
  def doc(nil), do: ""

  def doc(from) do
    from_text =
      case from do
        {:config, :base_url} ->
          "the `:base_url` option, else `config … base_url:`, else the spec's"

        other ->
          Values.source(other)
      end

    """


    ## Base URL

    The base URL comes from #{from_text}, when each request runs. A
    `base_url:` passed to `new/1`, `request/2` or a behaviour function is
    used as is.
    """
    |> String.trim_trailing()
    |> String.replace(~r/^(?=.)/m, "  ")
  end
end
