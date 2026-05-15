defmodule Hearth.Render.ModuleNames do
  @moduledoc false

  # Derives the module names for a generated integration.
  #
  # Verbose style only for now — the behaviour module repeats the
  # integration name so it greps cleanly:
  #
  #     <App>.Integrations.<Integration>.<Integration>Api
  #
  # With `--domain Billing` a domain segment slots in after the app:
  #
  #     <App>.Billing.Integrations.<Integration>.<Integration>Api
  #
  # `--style {tight|split}` and `--no-integrations-segment` are
  # v1-scoped flags not yet wired.
  #
  # All inputs (`:app_module`, `:integration`, `:domain`) are expected
  # to be already-camelized strings.

  # Layer 1 — the raw Req client: <App>.[<Domain>.]Integrations.<Integration>
  @spec layer1(keyword()) :: module()
  def layer1(opts), do: Module.concat(segments(opts))

  # Layer 2 — the behaviour: <App>.[<Domain>.]Integrations.<Integration>.<Integration>Api
  @spec layer2(keyword()) :: module()
  def layer2(opts) do
    Module.concat(segments(opts) ++ ["#{integration(opts)}Api"])
  end

  defp segments(opts) do
    [Keyword.fetch!(opts, :app_module), opts[:domain], "Integrations", integration(opts)]
    |> Enum.reject(&is_nil/1)
  end

  defp integration(opts), do: Keyword.fetch!(opts, :integration)
end
