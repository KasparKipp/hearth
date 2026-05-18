defmodule Hearth.Render.ModuleNames do
  @moduledoc false

  # Derives the module names for a generated integration.
  #
  # The layout is `<App>.<Domain>.<Integration>` plus per-layer
  # suffixes. The **domain** is the single namespace segment between
  # the app and the integration. It defaults to `Integrations` and is
  # overridden wholesale by `--domain` — the user is never locked into
  # a fixed naming pattern:
  #
  #     <App>.Integrations.<Integration>      (no --domain — the default)
  #     <App>.Billing.<Integration>           (--domain Billing)
  #
  # The behaviour module (Layer 2) repeats the integration name so it
  # greps cleanly: `…<Integration>.<Integration>Api`.
  #
  # `--style {tight|split}` is a v1-scoped flag not yet wired.
  #
  # All inputs (`:app_module`, `:integration`, `:domain`) are
  # already-camelized strings; `:domain` may be nil (→ `Integrations`).

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
  # segment defaults to `Integrations` when `--domain` is not given.
  defp segments(opts) do
    [Keyword.fetch!(opts, :app_module), opts[:domain] || "Integrations", integration(opts)]
  end

  defp integration(opts), do: Keyword.fetch!(opts, :integration)
end
