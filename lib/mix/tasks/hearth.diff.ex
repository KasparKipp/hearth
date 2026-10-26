defmodule Mix.Tasks.Hearth.Diff.Docs do
  @moduledoc false

  def short_doc do
    "Reports drift between Hearth integrations and their source specs. Requires igniter to run."
  end

  def example do
    "mix hearth.diff stripe"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Usage

        mix hearth.diff <integration>[,<integration>...] [--fail-on any|breaking]
        mix hearth.diff --all [--fail-on any|breaking]
        mix hearth.diff <integration> --source <spec> [--fail-on any|breaking]

    Re-prunes each integration's source spec (its `.hearth.exs`
    `source:`) with the entry's `tags:`, and compares the result with
    the pruned spec in `priv/hearth/`. It lists every change:
    operations added, removed, moved or renamed; parameters, request
    bodies and responses; and component schemas — properties, required
    fields, enum values, types. Each change is marked breaking or not.
    Documentation-only changes are ignored. An operationId rename at
    the same method and path is drift, not breaking: the report names
    the call sites to rename, and `--sync` keeps the operation selected.

    It also lists new upstream operations that `tags:` doesn't select,
    so you can decide on them. Those never fail the run.

    `hearth.diff` writes nothing. It exits non-zero when it finds
    drift, so it can run in CI. Apply the drift with
    `mix hearth.regen <integration> --sync`.

    The entry's `source_sha256`, recorded by `gen` and `--sync`, tells
    whether the source changed since then, or the drift comes from a
    local edit.

    ## Options

      * `--all` — check every integration in `.hearth.exs`.
      * `--source <spec>` — compare one integration against another
        local spec file, e.g. a newer version, without editing
        `.hearth.exs`.
      * `--fail-on any|breaking` — `any` (the default) fails on any
        drift; `breaking` only on breaking changes, reporting the rest.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Hearth.Diff do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Hearth.Config
    alias Hearth.Config.Project
    alias Hearth.Diff.Messages
    alias Hearth.Fs.Content
    alias Hearth.Integration.Messages, as: IntegrationMessages
    alias Hearth.Integration.Names
    alias Hearth.Integration.Reprune
    alias Hearth.Spec.Drift
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Selection

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [all: :boolean, source: :string, fail_on: :string],
        positional: [{:integrations, optional: true}],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    # Drift is reported as an Igniter issue; exit non-zero then, so CI
    # fails. Igniter itself only prints issues.
    @impl Mix.Task
    def run(argv) do
      case super(argv) do
        :issues -> exit({:shutdown, 1})
        result -> result
      end
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      with {:ok, fail_on} <- fail_on(igniter),
           {:ok, igniter, %{integrations: integrations, registry: registry}} <-
             Project.load(igniter),
           igniter = Igniter.assign(igniter, :hearth_registry, registry),
           {:ok, selected} <- select(igniter, integrations),
           :ok <- check_source(igniter, selected) do
        Enum.reduce(selected, igniter, &diff(&2, &1, fail_on))
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp fail_on(igniter) do
      case igniter.args.options[:fail_on] do
        nil -> {:ok, :any}
        "any" -> {:ok, :any}
        "breaking" -> {:ok, :breaking}
        other -> {:error, Messages.bad_fail_on_message(other)}
      end
    end

    defp select(igniter, integrations) do
      Names.select(
        integrations,
        igniter.args.positional[:integrations],
        igniter.args.options[:all],
        :diff
      )
    end

    defp check_source(igniter, selected) do
      if igniter.args.options[:source] && (igniter.args.options[:all] || length(selected) != 1),
        do: {:error, Messages.source_needs_one_message()},
        else: :ok
    end

    defp diff(igniter, {key, entry}, fail_on) do
      spec_path = Names.spec_path(key)

      with {:ok, igniter, current} <- read_pruned(igniter, key, spec_path),
           {:ok, igniter, result} <- reprune(igniter, key, entry, current) do
        changes = Drift.compare(current, result.pruned)
        unlisted = Selection.unlisted(result.operations, result.rule)

        report =
          Messages.report(
            key,
            result.source,
            changes,
            unlisted,
            source_state(entry, result.sha256),
            result.source == Config.source_label(Config.source(entry) || "")
          )
          |> Kernel.<>(split_advice(key, Reprune.splits(result, current)))

        igniter =
          if fails?(changes, fail_on),
            do: Igniter.add_issue(igniter, report),
            else: Igniter.add_notice(igniter, report)

        note_stale_overrides(igniter, key, result)
      else
        {:halt, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp read_pruned(igniter, key, spec_path) do
      igniter = Igniter.include_existing_file(igniter, spec_path)

      with true <- Igniter.exists?(igniter, spec_path) or :missing,
           {:ok, bytes} <- Content.read(igniter, spec_path),
           {:ok, spec} <- Loader.decode(bytes, :yaml) do
        {:ok, igniter, spec}
      else
        :missing -> {:halt, Messages.missing_spec_message(key, spec_path)}
        {:error, reason} -> {:halt, Messages.failed_to_parse_message(spec_path, reason)}
      end
    end

    defp reprune(igniter, key, entry, current) do
      opts = [
        source: igniter.args.options[:source],
        current: current,
        registry: igniter.assigns[:hearth_registry]
      ]

      case Reprune.run(igniter, entry, opts) do
        {:ok, igniter, result} ->
          {:ok, igniter, result}

        {:error, source, reason} ->
          {:halt,
           IntegrationMessages.reprune_message(
             :diff,
             key,
             source,
             reason,
             igniter.assigns[:hearth_registry]
           )}
      end
    end

    # Igniter prints only the issues when there are any, so the advice
    # rides in the report.
    defp split_advice(_key, []), do: ""
    defp split_advice(key, splits), do: "\n" <> IntegrationMessages.split_warning(key, splits)

    defp note_stale_overrides(igniter, _key, %{stale_overrides: []}), do: igniter

    defp note_stale_overrides(igniter, key, result) do
      notice =
        IntegrationMessages.stale_overrides_notice(key, result.source, result.stale_overrides)

      Igniter.add_notice(igniter, notice)
    end

    defp source_state(entry, sha256) do
      case entry[:source_sha256] do
        nil -> nil
        ^sha256 -> :unchanged
        recorded when is_list(recorded) and is_list(sha256) -> changed_sources(recorded, sha256)
        _other -> :changed
      end
    end

    # `sources:` — the keys whose checksum differs from the recorded one.
    defp changed_sources(recorded, sha256) do
      case for({key, sha} <- sha256, recorded[key] != sha, do: key) do
        [] -> :unchanged
        keys -> {:changed, keys}
      end
    end

    defp fails?([], _fail_on), do: false
    defp fails?(_changes, :any), do: true
    defp fails?(changes, :breaking), do: Drift.breaking?(changes)
  end
else
  defmodule Mix.Tasks.Hearth.Diff do
    @shortdoc "#{Mix.Tasks.Hearth.Diff.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc Mix.Tasks.Hearth.Diff.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'hearth.diff' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
