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
      * prints a summary notice tailored to the run:
        - first install — full explainer for `:hearth_domains`, version stamp,
          modified-files list, and pointers to `mix hearth.gen`.
        - repeat install that modified files — short header with the file list.
        - repeat install with no changes — single-line "already installed".

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

    # Files this task may touch. Used to compute a "modified" summary so
    # users running with --yes don't have to git diff to see what happened.
    @watched_files [".formatter.exs", "config/config.exs"]

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      otp_app = Igniter.Project.Application.app_name(igniter)
      first_install? = not domains_configured?(igniter, otp_app)

      igniter =
        igniter
        |> Igniter.Project.Formatter.import_dep(:hearth)
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          otp_app,
          [:hearth_domains],
          []
        )

      add_install_summary(igniter, first_install?, otp_app, files_touched(igniter))
    end

    defp domains_configured?(igniter, otp_app) do
      Igniter.Project.Config.configures_key?(
        igniter,
        "config.exs",
        otp_app,
        :hearth_domains
      )
    end

    defp files_touched(igniter) do
      Enum.filter(@watched_files, &Igniter.has_changes?(igniter, [&1]))
    end

    # Three notice branches:
    #
    #   * first-time install  -> full explainer (what :hearth_domains is, how
    #     to populate it, how to opt out, how to generate the first integration)
    #   * repeat run, files changed -> short header with the modified files
    #   * repeat run, no changes    -> single-line "already installed" confirmation
    defp add_install_summary(igniter, true, otp_app, changed) do
      Igniter.add_notice(igniter, first_install_notice(otp_app, changed))
    end

    defp add_install_summary(igniter, false, _otp_app, []) do
      Igniter.add_notice(
        igniter,
        "Hearth v#{hearth_version()} already installed — no changes."
      )
    end

    defp add_install_summary(igniter, false, _otp_app, changed) do
      Igniter.add_notice(igniter, """
      === Hearth v#{hearth_version()} ===

      Modified: #{Enum.join(changed, ", ")}
      """)
    end

    defp first_install_notice(otp_app, changed_files) do
      app_module = Macro.camelize(to_string(otp_app))

      modified_block =
        changed_files
        |> Enum.map(&"  • #{&1}")
        |> Enum.join("\n")

      """
      === Hearth v#{hearth_version()} installed ===

      Modified:
      #{modified_block}

      Hearth tracks managed integrations in your application's `:hearth_domains`
      configuration. As you generate integrations, add them to the list:

          config #{inspect(otp_app)}, hearth_domains: [
            #{app_module}.Billing.Stripe,
            #{app_module}.Notifications.SendGrid
          ]

      To opt out of tracking, set the value to `false`. `mix hearth.install`
      will not overwrite an explicit value on re-run.

      Next: generate your first integration. You will need an OpenAPI 3.x spec
      (YAML or JSON) — many vendors publish one (Stripe, GitHub, …), or you
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
