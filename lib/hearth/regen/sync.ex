if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Regen.Sync do
    @moduledoc false

    # `mix hearth.regen <name> --sync`: re-prunes the integration's spec
    # from its `.hearth.exs` `source:` with the selection its `tags:`
    # declare (`Hearth.Integration.Reprune`), rewrites the pruned spec,
    # and re-records `tags:` in its canonical form (an operation that
    # appeared under an `:all` tag shows up there) and `source_sha256`.
    # The task then renders from the returned pruned spec as usual.
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
    alias Hearth.Integration.Messages, as: IntegrationMessages
    alias Hearth.Integration.Reprune
    alias Hearth.Regen.Messages
    alias Hearth.Spec.Auth
    alias Hearth.Spec.Drift
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Selection

    @type changes :: %{
            added: [{atom(), String.t()}],
            removed: [Operation.t()],
            renamed: [{String.t(), String.t()}],
            auth: Auth.strategy() | nil
          }

    @spec run(Igniter.t(), atom(), Config.entry(), String.t()) ::
            {:ok, Igniter.t(), map(), changes()} | {:halt, String.t()}
    def run(igniter, key, entry, spec_path) do
      previous = previous(igniter, spec_path)

      registry = igniter.assigns[:hearth_registry] || %{}

      case Reprune.run(igniter, entry, current: previous, registry: registry) do
        {:ok, igniter, result} ->
          {added, removed} = changes(Operation.extract(previous), result.selected)
          renamed = renamed(Operation.extract(previous), Operation.extract(result.pruned))
          auth = auth_change(previous, result.pruned)
          drift = Drift.compare(previous, result.pruned)
          fields = Selection.describe(result.operations, result.selected)

          igniter =
            igniter
            |> Igniter.create_new_file(spec_path, result.yaml, on_exists: :overwrite)
            |> Project.put_fields(
              key,
              fields ++ auth_field(result) ++ [source_sha256: result.sha256]
            )
            |> Igniter.add_notice(Messages.synced_notice(key, result.source, spec_path, drift))

          igniter = note_stale_overrides(igniter, key, result)

          {:ok, igniter, result.pruned,
           %{added: Enum.map(added, &key/1), removed: removed, renamed: renamed, auth: auth}}

        {:error, source, reason} ->
          {:halt, IntegrationMessages.reprune_message(:regen, key, source, reason, registry)}
      end
    end

    defp note_stale_overrides(igniter, _key, %{stale_overrides: []}), do: igniter

    defp note_stale_overrides(igniter, key, result) do
      notice =
        IntegrationMessages.stale_overrides_notice(key, result.source, result.stale_overrides)

      Igniter.add_notice(igniter, notice)
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

        renamed = Enum.filter(changes.renamed, fn {old, _new} -> calls?(content, old) end)

        igniter
        |> append_tests(names, location, added)
        |> note_stale(location, Enum.filter(changes.removed, &calls?(content, &1)))
        |> note_renamed(location, renamed)
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

    defp note_renamed(igniter, _location, []), do: igniter

    defp note_renamed(igniter, location, renamed),
      do: Igniter.add_notice(igniter, Messages.external_renamed_notice(location, renamed))

    defp accept?(igniter, location, ids) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?(Messages.external_prompt(location, ids), default: :no)
    end

    # Whether the external test already calls the operation's Layer 3
    # function — as a test Hearth wrote, or one the user did.
    defp calls?(content, %Operation{id: id}), do: calls?(content, id)
    defp calls?(content, function), do: content =~ ~r/\.Req\.#{function}\(/

    # The pruned spec as it was before this sync — empty when it's
    # missing or unreadable.
    defp previous(igniter, spec_path) do
      igniter = Igniter.include_existing_file(igniter, spec_path)

      with true <- Igniter.exists?(igniter, spec_path),
           {:ok, bytes} <- Content.read(igniter, spec_path),
           {:ok, spec} <- Loader.decode(bytes, :yaml) do
        spec
      else
        _ -> %{}
      end
    end

    defp changes(before, selected) do
      before_keys = MapSet.new(before, &key/1)
      selected_keys = MapSet.new(selected, &key/1)

      {Enum.reject(selected, &MapSet.member?(before_keys, key(&1))),
       Enum.reject(before, &MapSet.member?(selected_keys, key(&1)))}
    end

    # Generated function names that changed at the same method + path —
    # an upstream operationId rename.
    defp renamed(before, now) do
      now_functions = Map.new(now, &{key(&1), &1.id})

      for op <- before,
          function = now_functions[key(op)],
          function && function != op.id,
          do: {op.id, function}
    end

    defp auth_field(%{auth: []}), do: []
    defp auth_field(%{auth: auth}), do: [auth: auth]

    # The new auth strategy when the sync changed it, so the task can
    # wire its credential config; nil otherwise.
    defp auth_change(previous, pruned) do
      new = Auth.strategy(pruned)
      if previous != %{} and Auth.strategy(previous) != new, do: new
    end

    defp key(%Operation{method: method, path: path}), do: {method, path}
  end
end
