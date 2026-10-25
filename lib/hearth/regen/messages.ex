defmodule Hearth.Regen.Messages do
  @moduledoc false

  # Every multi-line user-facing text `mix hearth.regen` prints —
  # notices and issues. Pure: strings in, strings out. Kept out of the
  # task module so the task reads as the pipeline it is.

  alias Hearth.Spec.BasePath

  @spec_dir "priv/hearth"

  def regen_notice(names, spec_path, results) do
    lines =
      Enum.map_join(results, "\n", fn {location, action} -> result_line(action, location) end)

    """
    Regenerated #{inspect(names.layer1)} from #{spec_path}.

    #{lines}

    Files with no ownership token are overwritten; `hearth:owned`
    files are skipped. Edit the pruned spec and re-run to pull in
    upstream changes.
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
    with; its pruned spec lives at #{@spec_dir}/<name>.yaml.
    """
  end

  def names_and_all_message do
    """
    hearth.regen: pass integration names or --all, not both.
    """
  end

  def no_specs_message do
    """
    hearth.regen: no pruned specs under #{@spec_dir}/ to regenerate.

    `mix hearth.gen` writes one per integration.
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

  def moved_notice(old, new, spec_path, old_files) do
    files = Enum.map_join(old_files, "\n", &"  * #{&1}")

    """
    Moved #{new.integration} from #{inspect(old.layer1)} to #{inspect(new.layer1)}.

    #{spec_path} now names #{inspect(new.layer1)}, and its mock and
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

  def removed_notice(old, new, spec_path, results) do
    {removed, kept} = Enum.split_with(results, &match?({_path, :removed}, &1))
    removed = Enum.map_join(removed, "\n", fn {path, _} -> "  * #{path}" end)

    """
    Moved #{new.integration} from #{inspect(old.layer1)} to #{inspect(new.layer1)}, removing the old module.

    #{spec_path} now names #{inspect(new.layer1)}, and its mock and
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

  def bad_module_message(spec_path, value) do
    found = if value, do: " (found #{inspect(value)})", else: ""

    """
    hearth.regen: #{spec_path} has no valid `x-hearth.module`#{found}.

    It must name the integration's Layer 1 module — the raw client
    `mix hearth.gen` created — so every other layer can be derived:

      x-hearth:
        module: MyApp.Integrations.Stripe
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
    or lower `x-hearth.base_path` in #{spec_path} to a prefix every
    path shares — and update the `base_url` config to match.
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
