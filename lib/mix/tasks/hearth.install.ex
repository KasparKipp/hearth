defmodule Mix.Tasks.Hearth.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs `Hearth`. Call with `mix igniter.install hearth`. Requires igniter to run."
  end

  def example do
    "mix hearth.install"
  end

  def long_doc do
    """
    #{short_doc()}

    Sets up your project to use Hearth:

      * imports Hearth's formatter rules into `.formatter.exs`
      * initializes `config :<otp_app>, :hearth_domains, []` in `config/config.exs`
        if (and only if) the key is not already set. Existing values — including
        an explicit `false` opt-out — are preserved.

    ## Example

    ```bash
    #{example()}
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Hearth.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [yes: :boolean],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      otp_app = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.Project.Formatter.import_dep(:hearth)
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        otp_app,
        [:hearth_domains],
        []
      )
    end
  end
else
  defmodule Mix.Tasks.Hearth.Install do
    @shortdoc "#{Mix.Tasks.Hearth.Install.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc Mix.Tasks.Hearth.Install.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'hearth.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
