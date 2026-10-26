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

    Sets up your project to use Hearth: imports Hearth's formatter rules
    into `.formatter.exs`, then prints a notice — the version, the
    modified file and a pointer to `mix hearth.gen` on first install, or
    a single "already installed" line when there was nothing to do.

    You normally only run this once per project. `mix hearth.gen` will
    invoke it automatically on a fresh project (prompting unless `--yes`
    is passed), so most users never need to call `hearth.install` directly.

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
        only: [:dev, :test],
        dep_opts: [runtime: false],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter = Igniter.Project.Formatter.import_dep(igniter, :hearth)

      if Igniter.has_changes?(igniter, [".formatter.exs"]) do
        Igniter.add_notice(igniter, installed_notice())
      else
        Igniter.add_notice(igniter, "Hearth v#{hearth_version()} already installed — no changes.")
      end
    end

    defp installed_notice do
      """
      === Hearth v#{hearth_version()} installed ===

      Modified:
        • .formatter.exs

      Next: generate your first integration. You will need an OpenAPI 3.x or
      Swagger 2.0 spec (YAML or JSON) — many vendors publish one (Stripe, GitHub, …), or you
      can hand-write a small one for a single endpoint. Then run:

          mix hearth.gen priv/specs/<api>.yaml --integration <Name>
      """
    end

    defp hearth_version do
      case Application.spec(:hearth, :vsn) do
        nil -> "unknown"
        vsn -> to_string(vsn)
      end
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
