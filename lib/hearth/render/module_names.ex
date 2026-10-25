defmodule Hearth.Render.ModuleNames do
  @moduledoc false

  # Derives the module names for a generated integration.
  #
  # The layout is `<App>.<Domain>.<Integration>` plus per-layer
  # suffixes. The **domain** is the single namespace segment between
  # the app and the integration. It defaults to `Integrations`, is
  # overridden wholesale by `--domain`, and is dropped entirely by
  # `--no-domain` — the user is never locked into a fixed pattern:
  #
  #     <App>.Integrations.<Integration>      (no flag — the default)
  #     <App>.Billing.<Integration>           (--domain Billing)
  #     <App>.<Integration>                   (--no-domain)
  #
  # The behaviour module (Layer 2) repeats the integration name so it
  # greps cleanly: `…<Integration>.<Integration>Api`.
  #
  # `--style {tight|split}` is a v1-scoped flag not yet wired.
  #
  # All inputs (`:app_module`, `:integration`, `:domain`) are
  # already-camelized strings; `:domain` may be nil (→ `Integrations`)
  # or `""` (→ no domain segment).

  # Layer 1 — the raw Req client: <App>.<Domain>.<Integration>
  @spec layer1(keyword()) :: module()
  def layer1(opts), do: Module.concat(segments(opts))

  # Layer 2 — the behaviour: <App>.<Domain>.<Integration>.<Integration>Api
  @spec layer2(keyword()) :: module()
  def layer2(opts) do
    Module.concat(segments(opts) ++ ["#{integration(opts)}Api"])
  end

  # Layer 3 — the Req implementation: <Layer2>.Req
  @spec layer3(keyword()) :: module()
  def layer3(opts) do
    Module.concat(segments(opts) ++ ["#{integration(opts)}Api", "Req"])
  end

  # Layer 1 test — a sibling of Layer 1, the integration name plus a
  # `Test` suffix: <App>.<Domain>.<Integration>Test. The `Test` suffix
  # is load-bearing — `Igniter.Project.Module` routes a `…Test` module
  # into `test/`.
  @spec layer1_test(keyword()) :: module()
  def layer1_test(opts) do
    Module.concat(Enum.drop(segments(opts), -1) ++ ["#{integration(opts)}Test"])
  end

  # Mock — the Mox double for Layer 2: <Layer2>.Mock
  @spec mock(keyword()) :: module()
  def mock(opts) do
    Module.concat(segments(opts) ++ ["#{integration(opts)}Api", "Mock"])
  end

  # External test — a sibling of Layer 1, the integration name plus an
  # `ExternalTest` suffix: <App>.<Domain>.<Integration>ExternalTest.
  # The `Test` suffix routes it into `test/` (see `layer1_test/1`).
  @spec external_test(keyword()) :: module()
  def external_test(opts) do
    Module.concat(Enum.drop(segments(opts), -1) ++ ["#{integration(opts)}ExternalTest"])
  end

  # The shared `<App>.<Domain>.<Integration>` prefix. The domain
  # segment defaults to `Integrations` when `--domain` is not given;
  # an empty-string domain (`--no-domain`) drops the segment entirely.
  defp segments(opts) do
    domain = opts[:domain] || "Integrations"

    [Keyword.fetch!(opts, :app_module), domain, integration(opts)]
    |> Enum.reject(&(&1 == ""))
  end

  defp integration(opts), do: Keyword.fetch!(opts, :integration)

  # Derives every layer module for an already-generated integration
  # from its Layer 1 module alone — the integration name is the
  # module's last segment, and the layout below it is fixed. This is
  # the inverse of building from `[:app_module, :domain, :integration]`
  # and is what `mix hearth.regen` uses: the pruned spec records the
  # Layer 1 module (`x-hearth.module`), everything else follows.
  @spec from_layer1(module()) :: %{
          integration: String.t(),
          layer1: module(),
          layer2: module(),
          layer3: module(),
          layer1_test: module(),
          external_test: module(),
          mock: module()
        }
  def from_layer1(layer1) when is_atom(layer1) do
    segments = Module.split(layer1)
    integration = List.last(segments)
    parent = Enum.drop(segments, -1)
    api = "#{integration}Api"

    %{
      integration: integration,
      layer1: layer1,
      layer2: Module.concat(segments ++ [api]),
      layer3: Module.concat(segments ++ [api, "Req"]),
      layer1_test: Module.concat(parent ++ ["#{integration}Test"]),
      external_test: Module.concat(parent ++ ["#{integration}ExternalTest"]),
      mock: Module.concat(segments ++ [api, "Mock"])
    }
  end

  # A name that must camelize to a single Elixir alias segment — a
  # `--integration` / `--domain` value for `gen`, an integration name
  # for `regen`: a letter then letters/digits, no spaces, dots or
  # empty. snake_case input is fine (`Macro.camelize` folds it).
  @spec valid_segment?(String.t()) :: boolean()
  def valid_segment?(name) when is_binary(name) do
    Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, Macro.camelize(name))
  end

  # Parses a dotted module name as written in the pruned spec's
  # `x-hearth.module` — a user-editable file, so validated: every
  # segment a proper alias (no lowercase, no empty segments). A
  # leading `Elixir.` is tolerated.
  @spec parse(term()) :: {:ok, module()} | :error
  def parse(name) when is_binary(name) do
    segments = name |> String.replace_prefix("Elixir.", "") |> String.split(".")

    if Enum.all?(segments, &Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, &1)),
      do: {:ok, Module.concat(segments)},
      else: :error
  end

  def parse(_name), do: :error
end
