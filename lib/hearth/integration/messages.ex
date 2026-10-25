defmodule Hearth.Integration.Messages do
  @moduledoc false

  # User-facing text shared by the tasks that act on existing
  # integrations — `mix hearth.regen` and `mix hearth.diff`: naming
  # integrations, and re-pruning one from its source. `task` is the
  # task's short name (`:regen`, `:diff`), used in the prefix and the
  # example commands. Pure: strings in, strings out.

  def missing_integration_message(task) do
    """
    hearth.#{task}: name the integrations to #{verb(task)}, or pass --all.

      mix hearth.#{task} stripe
      mix hearth.#{task} stripe,send_grid
      mix hearth.#{task} --all

    An integration's name is the `--integration` it was generated
    with — its key in `.hearth.exs`.
    """
  end

  def names_and_all_message(task) do
    """
    hearth.#{task}: pass integration names or --all, not both.
    """
  end

  def no_integrations_message(task) do
    """
    hearth.#{task}: no integrations in .hearth.exs to #{verb(task)}.

    `mix hearth.gen` adds an entry per integration.
    """
  end

  def missing_entry_message(task, keys) do
    names = Enum.map_join(keys, ", ", &Atom.to_string/1)
    integration = keys |> hd() |> Atom.to_string() |> Macro.camelize()

    """
    hearth.#{task}: no integration named #{names} in .hearth.exs.

    `mix hearth.gen` adds an entry per integration, keyed by its
    snake_case name. Generate it first:

      mix hearth.gen <source> --integration #{integration}
    """
  end

  def bad_names_message(task, bad) do
    names = Enum.map_join(bad, ", ", &inspect/1)

    """
    hearth.#{task}: #{names} is not an integration name.

    Use the name the integration was generated with — a single
    alias segment, e.g. `stripe` or `SendGrid` — not its module.
    Separate several names with commas.
    """
  end

  def bad_tags_message(task, key, detail) do
    """
    hearth.#{task}: the .hearth.exs entry for #{key} has a malformed selection.

    #{detail}
    """
  end

  # Why `Hearth.Integration.Reprune` couldn't re-prune `key` from `source`.
  def reprune_message(task, key, _source, :no_tags) do
    """
    hearth.#{task}: #{key} is re-pruned from its source with the entry's
    `tags:`, but its .hearth.exs entry has none. Add one, e.g.

      #{key}: [module: …, source: …, tags: [Customers: :all]]
    """
  end

  def reprune_message(task, key, _source, {:bad_tags, detail}),
    do: bad_tags_message(task, key, detail)

  def reprune_message(task, key, _source, :no_source) do
    """
    hearth.#{task}: #{key} is re-pruned from its source, but its
    .hearth.exs entry has no `source:`.
    """
  end

  def reprune_message(task, key, source, :not_local) do
    """
    hearth.#{task}: #{key}: only local spec files can be read for now;
    #{inspect(source)} is a URL or registry source. Download the spec,
    point `source:` at the file, and re-run.
    """
  end

  def reprune_message(task, key, source, :missing) do
    "hearth.#{task}: #{key}: source #{inspect(source)} not found. " <>
      "Point `source:` in .hearth.exs at the spec file."
  end

  def reprune_message(task, key, source, :unsupported) do
    "hearth.#{task}: #{key}: unsupported spec format for #{inspect(source)}. " <>
      "Supported extensions: .yaml, .yml, .json."
  end

  def reprune_message(task, key, source, {:decode, reason}) do
    "hearth.#{task}: #{key}: failed to parse #{source}.\n\n" <> format_reason(reason)
  end

  def reprune_message(task, key, source, :empty_selection) do
    """
    hearth.#{task}: `tags:` for #{key} in .hearth.exs selects no operations in #{source}.
    """
  end

  defp verb(:regen), do: "regenerate"
  defp verb(:diff), do: "check"

  defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
  defp format_reason(reason), do: inspect(reason)
end
