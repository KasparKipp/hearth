defmodule Hearth.Regen.Messages do
  @moduledoc false

  # Every multi-line user-facing text `mix hearth.regen` prints —
  # notices and issues. Pure: strings in, strings out. Kept out of the
  # task module so the task reads as the pipeline it is.

  alias Hearth.Spec.BasePath

  def regen_notice(names, spec_path, results) do
    lines =
      Enum.map_join(results, "\n", fn {location, action} -> result_line(action, location) end)

    """
    Regenerated #{inspect(names.layer1)} from #{spec_path}.

    #{lines}

    Files with no ownership token are overwritten; `hearth:owned`
    files are skipped. To change the operations, edit `tags:` in
    .hearth.exs and re-run with --sync.
    """
  end

  defp result_line(:regenerated, location), do: "* regenerating #{location}"
  defp result_line(:created, location), do: "* creating #{location}"
  defp result_line(:owned, location), do: "* skipping #{location} (hearth:owned)"

  defp result_line(:declined, location),
    do: "* skipping #{location} (hearth:collaborating, declined)"

  defp result_line(:kept, location), do: "* keeping #{location} (user-owned scaffold)"

  defp result_line(:unreadable, location),
    do: "* skipping #{location} (could not read it to check its ownership token)"

  def module_needs_one_message do
    """
    hearth.regen: --module moves exactly one integration.

      mix hearth.regen stripe --module MyApp.Payments.Stripe
    """
  end

  def bad_target_message(value) do
    """
    hearth.regen: --module #{inspect(value)} is not a module name.

    Use a dotted alias, e.g. `MyApp.Payments.Stripe`.
    """
  end

  def target_rename_message(value, integration) do
    """
    hearth.regen: --module #{inspect(value)} must end in #{integration}.

    --module changes the integration's namespace, not its name —
    e.g. `MyApp.Payments.#{integration}`.
    """
  end

  def target_exists_message(module, existing) do
    files = Enum.map_join(existing, "\n", &"  * #{&1}")

    """
    hearth.regen: #{inspect(module)} already exists.

    These files are present:

    #{files}

    --module only creates the new module. Pick another module, or
    delete these files.
    """
  end

  def moved_notice(old, new, old_files) do
    files = Enum.map_join(old_files, "\n", &"  * #{&1}")

    """
    Moved #{new.integration} from #{inspect(old.layer1)} to #{inspect(new.layer1)}.

    .hearth.exs now names #{inspect(new.layer1)}, and its mock and
    config are wired. #{inspect(old.layer1)} is untouched — once
    callers use the new module, delete its files:

    #{files}

    and its entries in config/*.exs and test/support/mocks.ex.
    """
  end

  def remove_old_needs_module_message do
    """
    hearth.regen: --remove-old only works with --module <NewLayer1Module>.

      mix hearth.regen stripe --module MyApp.Payments.Stripe --remove-old

    It removes the integration's old module after moving it.
    """
  end

  def removed_notice(old, new, results) do
    {removed, kept} = Enum.split_with(results, &match?({_path, :removed}, &1))
    removed = Enum.map_join(removed, "\n", fn {path, _} -> "  * #{path}" end)

    """
    Moved #{new.integration} from #{inspect(old.layer1)} to #{inspect(new.layer1)}, removing the old module.

    .hearth.exs now names #{inspect(new.layer1)}, and its mock and
    config are wired. #{inspect(old.layer1)}'s config entries and
    defmock are removed, and these files:

    #{removed}
    #{kept_section(kept)}
    """
  end

  defp kept_section([]), do: ""

  defp kept_section(kept) do
    files =
      Enum.map_join(kept, "\n", fn {path, claim} -> "  * #{path} (#{claim_label(claim)})" end)

    """

    Kept, because they're yours. They still reference the removed
    modules — delete them once you've moved what you need:

    #{files}
    """
  end

  defp claim_label(:scaffold), do: "user-owned scaffold"
  defp claim_label(:owned), do: "hearth:owned"
  defp claim_label(:collaborating), do: "hearth:collaborating"
  defp claim_label(:unreadable), do: "could not read it to check its ownership token"

  def bad_module_message(key, value) do
    found = if value, do: " (found #{inspect(value)})", else: ""
    integration = key |> Atom.to_string() |> Macro.camelize()

    """
    hearth.regen: the .hearth.exs entry for #{key} has no valid `module:`#{found}.

    It must name the integration's Layer 1 module — the raw client
    `mix hearth.gen` created — as an alias, so every other layer can
    be derived:

      #{key}: [module: MyApp.Integrations.#{integration}, …]
    """
  end

  def base_path_mismatch_message(spec_path, prefix, operations) do
    outside =
      operations
      |> Enum.reject(&BasePath.prefix_of_all?([&1], prefix))
      |> Enum.map_join("\n", &"  * #{&1.path}")

    """
    hearth.regen: #{spec_path} has paths outside its recorded base path #{prefix}:

    #{outside}

    The base path is folded into the generated client's base URL and
    into `config/test.exs`. Either move these paths under #{prefix},
    or lower the integration's `base_path:` in .hearth.exs to a prefix
    every path shares — and update the `base_url` config to match.
    """
  end

  def selection_mismatch_message(key, spec_path, problems) do
    lines = Enum.map_join(problems, "\n", &"  * #{&1}")

    """
    hearth.regen: `tags:` for #{key} in .hearth.exs no longer matches #{spec_path}:

    #{lines}

    `tags:` decides which operations the pruned spec holds. Re-prune
    it from the source:

      mix hearth.regen #{key} --sync
    """
  end

  # `changes` — `Hearth.Spec.Drift` changes from the old pruned spec to
  # the new one, the same lines `mix hearth.diff` prints.
  def synced_notice(key, source, spec_path, changes) do
    changes =
      case changes do
        [] -> "No changes: the pruned spec already matched."
        changes -> Enum.map_join(changes, "\n", &Hearth.Spec.Drift.format/1)
      end

    """
    Synced #{key}: re-pruned #{spec_path} from #{source} with its `tags:`.

    #{changes}
    """
  end

  def sync_all_prompt(keys) do
    "hearth.regen: --sync --all re-prunes every integration from its source " <>
      "(#{Enum.join(keys, ", ")}). That can be a very large change — " <>
      "run `mix hearth.diff --all` first to see it. Continue?"
  end

  def sync_all_declined_message do
    """
    hearth.regen: --sync --all cancelled; nothing was changed. See the drift
    with `mix hearth.diff --all`, or sync one integration at a time.
    """
  end

  def external_prompt(location, ids) do
    "hearth.regen: append external tests for #{Enum.join(ids, ", ")} to #{location}?"
  end

  def external_appended_notice(location, ids) do
    """
    Appended external tests for #{Enum.join(ids, ", ")} to #{location}.
    Replace their placeholder args with real ones.
    """
  end

  def external_declined_notice(location, ids) do
    """
    Left #{location} alone. It has no tests yet for #{Enum.join(ids, ", ")}.
    """
  end

  def external_renamed_notice(location, renamed) do
    calls = Enum.map_join(renamed, ", ", fn {old, new} -> "#{old}, renamed to #{new}" end)

    """
    #{location} still calls #{calls}.
    Rename the calls — the old functions no longer exist.
    """
  end

  def external_stale_notice(location, ids) do
    """
    #{location} still calls #{Enum.join(ids, ", ")}, which --sync removed.
    Delete or rewrite those tests — the functions no longer exist.
    """
  end

  def missing_spec_message(spec_path) do
    integration = spec_path |> Path.basename(".yaml") |> Macro.camelize()

    """
    hearth.regen: no pruned spec for #{integration} at #{spec_path}.

    `mix hearth.regen` regenerates from the pruned spec that
    `mix hearth.gen` writes. Generate the integration first:

      mix hearth.gen <source> --integration #{integration}
    """
  end
end
