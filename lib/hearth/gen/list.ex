if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Gen.List do
    @moduledoc false

    # `mix hearth.gen --list`: introspection that generates nothing.
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config.Project
    alias Hearth.Gen.Messages
    alias Hearth.Integration.Load
    alias Hearth.Integration.Messages, as: IntegrationMessages
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Source

    # --list semantics:
    #
    #   * no source       → print the available shortcut names (Hearth's
    #     and the project's `.hearth.exs` registry)
    #   * registry source → print available versions for that shortcut
    #     (the @version part of the source is ignored — same answer for
    #     `stripe`, `stripe@latest`, or `stripe@anything-else`)
    #   * a file or URL   → load it and print its tag discovery
    @spec run(Igniter.t()) :: Igniter.t()
    def run(igniter) do
      # --list is pure introspection. Suppress Igniter's end-of-run
      # "No proposed content changes!" line so query-mode commands
      # don't leave that noise behind their actual output.
      igniter = Igniter.assign(igniter, :quiet_on_no_changes?, true)

      case Project.load(igniter) do
        {:ok, igniter, %{registry: registry}} ->
          list(igniter, igniter.args.positional[:source], registry)

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp list(igniter, nil, registry) do
      Mix.shell().info(Messages.format_shortcuts(registry))
      igniter
    end

    defp list(igniter, source, registry) do
      case Source.resolve(source) do
        {:registry, name_with_version} -> list_versions(igniter, name_with_version, registry)
        {:error, reason} -> Igniter.add_issue(igniter, "hearth.gen: #{reason}")
        _location -> list_tags(igniter, source, registry)
      end
    end

    defp list_versions(igniter, name_with_version, registry) do
      base = name_with_version |> String.split("@", parts: 2) |> hd()

      case Hearth.Registry.versions(base, registry) do
        nil ->
          reason = {:registry, {:unknown_name, base}}

          Igniter.add_issue(
            igniter,
            IntegrationMessages.load_message(:gen, base, reason, registry)
          )

        versions ->
          Mix.shell().info(Messages.format_versions(base, versions))
          igniter
      end
    end

    defp list_tags(igniter, source, registry) do
      case Load.load(igniter, source, registry) do
        {:ok, igniter, loaded} ->
          Mix.shell().info(
            Messages.tag_discovery(Operation.extract(loaded.spec),
              source: source,
              integration: igniter.args.options[:integration],
              limit: nil
            )
          )

          igniter

        {:error, reason} ->
          Igniter.add_issue(
            igniter,
            IntegrationMessages.load_message(:gen, source, reason, registry)
          )
      end
    end
  end
end
