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

  @spec layer2(keyword()) :: module()
  def layer2(opts) do
    app = Keyword.fetch!(opts, :app_module)
    integration = Keyword.fetch!(opts, :integration)
    domain = opts[:domain]

    [app, domain, "Integrations", integration, "#{integration}Api"]
    |> Enum.reject(&is_nil/1)
    |> Module.concat()
  end
end
