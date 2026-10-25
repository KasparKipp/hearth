if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Regen.Sync do
    @moduledoc false

    # `mix hearth.regen <name> --sync`: re-prunes the integration's spec
    # from its `.hearth.exs` `source:` with the selection its `tags:`
    # declare, rewrites the pruned spec, and re-records `tags:` in its
    # canonical form (an operation that appeared under an `:all` tag
    # shows up there). The task then renders from the returned pruned
    # spec as usual. Only local spec files are read today.
    #
    # The external test is a user-owned scaffold, so regen never
    # rewrites it. `extend_external_test/4` offers (y/N; `--yes` and test
    # mode accept) to append tests for the operations a sync added, and
    # names tests that still call an operation it removed.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config
    alias Hearth.Config.Project
    alias Hearth.Fs.Content
    alias Hearth.Regen.Messages
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Prune
    alias Hearth.Spec.Selection
    alias Hearth.Spec.Source

    @type changes :: %{added: [{atom(), String.t()}], removed: [Operation.t()]}

    @spec run(Igniter.t(), atom(), Config.entry(), String.t()) ::
            {:ok, Igniter.t(), map(), changes()} | {:halt, String.t()}
    def run(igniter, key, entry, spec_path) do
      with {:ok, rule} <- rule(key, entry),
           {:ok, source} <- source(key, entry),
           {:ok, igniter, spec} <- read_source(igniter, key, source),
           operations = Operation.extract(spec),
           {:ok, selected} <- select(key, source, operations, rule) do
        yaml = spec |> Prune.prune(selected) |> Prune.to_yaml()
        {:ok, pruned} = Loader.decode(yaml, :yaml)
        {added, removed} = changes(previous(igniter, spec_path), selected)

        igniter =
          igniter
          |> Igniter.create_new_file(spec_path, yaml, on_exists: :overwrite)
          |> Project.put_fields(key, Selection.describe(operations, selected))
          |> Igniter.add_notice(Messages.synced_notice(key, source, spec_path, added, removed))

        {:ok, igniter, pruned, %{added: Enum.map(added, &key/1), removed: removed}}
      end
    end

    @spec extend_external_test(Igniter.t(), map(), map(), changes() | nil) :: Igniter.t()
    def extend_external_test(igniter, _names, _spec, nil), do: igniter

    def extend_external_test(igniter, names, spec, changes) do
      location = Igniter.Project.Module.proper_location(igniter, names.external_test, :test)
      igniter = Igniter.include_existing_file(igniter, location)

      # A missing scaffold is created whole by the render that follows.
      with true <- Igniter.exists?(igniter, location),
           {:ok, content} <- Content.read(igniter, location) do
        added =
          spec
          |> Operation.extract()
          |> Enum.filter(&(key(&1) in changes.added and not calls?(content, &1)))

        igniter
        |> append_tests(names, location, added)
        |> note_stale(location, Enum.filter(changes.removed, &calls?(content, &1)))
      else
        _ -> igniter
      end
    end

    defp append_tests(igniter, _names, _location, []), do: igniter

    defp append_tests(igniter, names, location, added) do
      ids = Enum.map(added, & &1.id)

      if accept?(igniter, location, ids) do
        code = Hearth.Render.Tests.external_tests(names.layer2, added)

        igniter
        |> Igniter.update_elixir_file(location, &append_to_module(&1, names.external_test, code))
        |> Igniter.add_notice(Messages.external_appended_notice(location, ids))
      else
        Igniter.add_notice(igniter, Messages.external_declined_notice(location, ids))
      end
    end

    defp append_to_module(zipper, module, code) do
      with {:ok, zipper} <- Igniter.Code.Module.move_to_defmodule(zipper, module),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
        {:ok, Igniter.Code.Common.add_code(zipper, code)}
      else
        :error -> {:warning, "Could not find #{inspect(module)} to append external tests to."}
      end
    end

    defp note_stale(igniter, _location, []), do: igniter

    defp note_stale(igniter, location, removed) do
      ids = Enum.map(removed, & &1.id)
      Igniter.add_notice(igniter, Messages.external_stale_notice(location, ids))
    end

    defp accept?(igniter, location, ids) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?(Messages.external_prompt(location, ids))
    end

    # Whether the external test already calls the operation's Layer 3
    # function — as a test Hearth wrote, or one the user did.
    defp calls?(content, %Operation{id: id}), do: content =~ ~r/\.Req\.#{id}\(/

    defp rule(key, entry) do
      case Selection.rule(entry) do
        {:ok, rule} -> {:ok, rule}
        :none -> {:halt, Messages.sync_needs_tags_message(key)}
        {:error, message} -> {:halt, Messages.bad_tags_message(key, message)}
      end
    end

    defp source(key, entry) do
      case Config.source(entry) do
        nil -> {:halt, Messages.sync_needs_source_message(key)}
        source -> {:ok, source}
      end
    end

    defp read_source(igniter, key, source) do
      with {:file, path} <- Source.resolve(source),
           {:ok, igniter, spec} <- Content.read_spec(igniter, path) do
        {:ok, igniter, spec}
      else
        {:error, reason} -> {:halt, Messages.sync_source_message(key, source, reason)}
        _url_or_registry -> {:halt, Messages.sync_source_message(key, source, :not_local)}
      end
    end

    defp select(key, source, operations, rule) do
      case Selection.select(operations, rule) do
        [] -> {:halt, Messages.empty_selection_message(key, source)}
        selected -> {:ok, selected}
      end
    end

    # The operations in the pruned spec as it was before this sync —
    # none when it's missing or unreadable.
    defp previous(igniter, spec_path) do
      igniter = Igniter.include_existing_file(igniter, spec_path)

      with true <- Igniter.exists?(igniter, spec_path),
           {:ok, bytes} <- Content.read(igniter, spec_path),
           {:ok, spec} <- Loader.decode(bytes, :yaml) do
        Operation.extract(spec)
      else
        _ -> []
      end
    end

    defp changes(before, selected) do
      before_keys = MapSet.new(before, &key/1)
      selected_keys = MapSet.new(selected, &key/1)

      {Enum.reject(selected, &MapSet.member?(before_keys, key(&1))),
       Enum.reject(before, &MapSet.member?(selected_keys, key(&1)))}
    end

    defp key(%Operation{method: method, path: path}), do: {method, path}
  end
end
