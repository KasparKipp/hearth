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

  def missing_integration_message do
    """
    hearth.regen: name the integrations to regenerate, or pass --all.

      mix hearth.regen stripe
      mix hearth.regen stripe,send_grid
      mix hearth.regen --all

    An integration's name is the `--integration` it was generated
    with — its key in `.hearth.exs`.
    """
  end

  def names_and_all_message do
    """
    hearth.regen: pass integration names or --all, not both.
    """
  end

  def no_integrations_message do
    """
    hearth.regen: no integrations in .hearth.exs to regenerate.

    `mix hearth.gen` adds an entry per integration.
    """
  end

  def missing_entry_message(keys) do
    names = Enum.map_join(keys, ", ", &Atom.to_string/1)
    integration = keys |> hd() |> Atom.to_string() |> Macro.camelize()

    """
    hearth.regen: no integration named #{names} in .hearth.exs.

    `mix hearth.gen` adds an entry per integration, keyed by its
    snake_case name. Generate it first:

      mix hearth.gen <source> --integration #{integration}
    """
  end

  def bad_names_message(bad) do
    names = Enum.map_join(bad, ", ", &inspect/1)

    """
    hearth.regen: #{names} is not an integration name.

    Use the name the integration was generated with — a single
    alias segment, e.g. `stripe` or `SendGrid` — not its module.
    Separate several names with commas.
    """
  end

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

  def bad_tags_message(key, detail) do
    """
    hearth.regen: the .hearth.exs entry for #{key} has a malformed selection.

    #{detail}
    """
  end

  def sync_needs_tags_message(key) do
    """
    hearth.regen: --sync re-prunes #{key} from its source with the
    entry's `tags:`, but its .hearth.exs entry has none. Add one, e.g.

      #{key}: [module: …, source: …, tags: [Customers: :all]]
    """
  end

  def sync_needs_source_message(key) do
    """
    hearth.regen: --sync re-prunes #{key} from its source, but its
    .hearth.exs entry has no `source:`.
    """
  end

  def sync_source_message(key, source, :not_local) do
    """
    hearth.regen: --sync for #{key} reads local spec files only for
    now; #{inspect(source)} is a URL or registry source. Download the
    spec, point `source:` at the file, and re-run.
    """
  end

  def sync_source_message(key, source, :missing) do
    "hearth.regen: --sync for #{key}: source #{inspect(source)} not found. " <>
      "Point `source:` in .hearth.exs at the spec file."
  end

  def sync_source_message(key, source, :unsupported) do
    "hearth.regen: --sync for #{key}: unsupported spec format for #{inspect(source)}. " <>
      "Supported extensions: .yaml, .yml, .json."
  end

  def sync_source_message(key, source, {:decode, reason}) do
    "hearth.regen: --sync for #{key}: failed to parse #{source}.\n\n" <> format_reason(reason)
  end

  def empty_selection_message(key, source) do
    """
    hearth.regen: `tags:` for #{key} in .hearth.exs selects no operations in #{source}.
    """
  end

  def synced_notice(key, source, spec_path, added, removed) do
    changes =
      case Enum.map(added, &change_line("+", &1)) ++ Enum.map(removed, &change_line("-", &1)) do
        [] -> "The selected operations are unchanged."
        lines -> Enum.join(lines, "\n")
      end

    """
    Synced #{key}: re-pruned #{spec_path} from #{source} with its `tags:`.

    #{changes}
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

  def external_stale_notice(location, ids) do
    """
    #{location} still calls #{Enum.join(ids, ", ")}, which --sync removed.
    Delete or rewrite those tests — the functions no longer exist.
    """
  end

  defp change_line(sign, operation) do
    name = operation.operation_id || operation.id
    "#{sign} #{operation.method} #{operation.path} (#{name})"
  end

  defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
  defp format_reason(reason), do: inspect(reason)

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
