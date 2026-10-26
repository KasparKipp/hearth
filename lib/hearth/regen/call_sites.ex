if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Regen.CallSites do
    @moduledoc false

    # `regen --sync` can take a function away that callers use: an
    # upstream or `operation_ids:` rename gives it a new name, and a new
    # `prefixed_ids:` prefix covers it with a prefixed-id function
    # (`get_subscription/2` → `retrieve/2`). The arguments line up — path
    # params, then `opts` — so the callers can follow.
    #
    #   * `functions/2` — the callbacks the Layer 2 module declares before
    #     the sync renders, the record of what callers could use
    #   * `replacements/4` — old name → new name for the ones that go
    #   * `rewrite/4` — after a y/N prompt (`--yes` and test mode accept),
    #     renames the calls with `Igniter.Refactors.Rename.rename_function/4`
    #     on Layer 2 and Layer 3, and the function atoms in Mox `expect` /
    #     `stub` calls on the generated mock, across lib and test
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Fs.Content
    alias Hearth.Regen.Messages
    alias Hearth.Spec.Operation
    alias Hearth.Spec.PrefixedIds
    alias Sourceror.Zipper

    @mox_functions [:expect, :stub]

    @spec functions(Igniter.t(), map()) :: {Igniter.t(), MapSet.t(String.t())}
    def functions(igniter, names) do
      location = Igniter.Project.Module.proper_location(igniter, names.layer2, :source_folder)
      igniter = Igniter.include_existing_file(igniter, location)

      with true <- Igniter.exists?(igniter, location),
           {:ok, content} <- Content.read(igniter, location) do
        {igniter, ~r/@callback (\w+)\(/ |> Regex.scan(content) |> MapSet.new(&List.last/1)}
      else
        _ -> {igniter, MapSet.new()}
      end
    end

    # Old callback → the function that replaces it: a covered operation's
    # covering prefixed-id function, or a rename's new name. Only for
    # callbacks that existed and are gone after this sync.
    @spec replacements(MapSet.t(String.t()), map(), map() | nil, [{String.t(), String.t()}]) ::
            [{String.t(), String.t()}]
    def replacements(old, spec, prefixed, renamed) do
      covered =
        for {op, function} <- spec |> Operation.extract() |> PrefixedIds.covered(prefixed),
            MapSet.member?(old, op.id),
            do: {op.id, Atom.to_string(function)}

      renames = for {from, to} <- renamed, MapSet.member?(old, from), do: {from, to}

      Enum.uniq_by(covered ++ renames, &elem(&1, 0))
    end

    @spec accept?(Igniter.t(), [{String.t(), String.t()}]) :: boolean()
    def accept?(_igniter, []), do: false

    def accept?(igniter, replacements) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?(Messages.call_sites_prompt(replacements), default: :no)
    end

    @spec rewrite(Igniter.t(), map(), [{String.t(), String.t()}], boolean()) :: Igniter.t()
    def rewrite(igniter, _names, [], _accepted?), do: igniter

    def rewrite(igniter, _names, replacements, false),
      do: Igniter.add_notice(igniter, Messages.call_sites_left_notice(replacements))

    def rewrite(igniter, names, replacements, true) do
      replacements
      |> Enum.reduce(igniter, fn {from, to}, acc ->
        from = String.to_atom(from)
        to = String.to_atom(to)

        acc
        |> rename(names.layer2, from, to)
        |> rename(names.layer3, from, to)
      end)
      |> fresh()
      |> Igniter.update_all_elixir_files(&rename_mox_atoms(&1, names.mock, replacements))
      |> Igniter.add_notice(Messages.call_sites_moved_notice(names.layer2, replacements))
    end

    defp rename(igniter, module, from, to) do
      igniter
      |> fresh()
      |> Igniter.Refactors.Rename.rename_function({module, from}, {module, to})
    end

    # `Igniter.update_all_elixir_files/2` runs once per igniter — it then
    # marks every file included and skips later updaters. Each rename here
    # is its own pass, so clear the mark first.
    defp fresh(igniter) do
      private = Map.delete(igniter.assigns[:private] || %{}, :included_all_elixir_files?)
      %{igniter | assigns: Map.put(igniter.assigns, :private, private)}
    end

    # `expect(Mock, :old, …)`, `stub(Mock, :old, …)`, imported or as
    # `Mox.expect(…)`, become `:new`.
    defp rename_mox_atoms(zipper, mock, replacements) do
      atoms =
        Map.new(replacements, fn {from, to} -> {String.to_atom(from), String.to_atom(to)} end)

      Igniter.Code.Common.update_all_matches(
        zipper,
        &mox_call?(&1, mock, atoms),
        fn zipper ->
          # The call's own argument list — the same for `expect(…)` and
          # `Mox.expect(…)`, unlike the zipper's children.
          {:ok,
           Zipper.update(zipper, fn {call, meta, args} ->
             {call, meta, List.update_at(args, 1, &replace_atom(&1, atoms))}
           end)}
        end
      )
    end

    defp replace_atom({:__block__, meta, [atom]}, atoms) when is_map_key(atoms, atom),
      do: {:__block__, meta, [Map.fetch!(atoms, atom)]}

    defp replace_atom(atom, atoms) when is_map_key(atoms, atom), do: Map.fetch!(atoms, atom)
    defp replace_atom(node, _atoms), do: node

    defp mox_call?(zipper, mock, atoms) do
      Enum.any?(@mox_functions, fn function ->
        Igniter.Code.Function.function_call?(zipper, function, [3, 4]) or
          Igniter.Code.Function.function_call?(zipper, {Mox, function}, [3, 4])
      end) and
        Igniter.Code.Function.argument_equals?(zipper, 0, mock) and
        Igniter.Code.Function.argument_matches_predicate?(zipper, 1, fn arg ->
          Map.has_key?(atoms, atom_value(arg.node))
        end)
    end

    defp atom_value({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
    defp atom_value(atom) when is_atom(atom), do: atom
    defp atom_value(_node), do: nil
  end
end
