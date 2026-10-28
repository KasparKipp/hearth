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

  def bad_auth_message(task, key, name, available) do
    schemes = if available == [], do: "none", else: Enum.join(available, ", ")

    """
    hearth.#{task}: the .hearth.exs entry for #{key} chooses an auth scheme the spec doesn't have: #{inspect(name)}.

    `auth: [scheme: …]` must name one of the spec's security schemes: #{schemes}.
    """
  end

  def bad_prefixed_ids_message(task, key, detail) do
    """
    hearth.#{task}: the .hearth.exs entry for #{key} has a problem in `prefixed_ids:`.

    #{detail}
    """
  end

  # `headers:`, `credential:` or `base_url:` — the detail names which.
  def bad_values_message(task, key, detail) do
    """
    hearth.#{task}: the .hearth.exs entry for #{key} has a problem.

    #{detail}
    """
  end

  def auth_header_message(task, key, names, auth) do
    """
    hearth.#{task}: `headers:` for #{key} names #{Enum.map_join(names, ", ", &inspect/1)}, \
    which the credential (#{Hearth.Spec.Auth.label(auth)}) already sends, so its value would
    never be used. Drop it from `headers:`; to change where the credential comes
    from, use `auth: [credential: …]`.
    """
  end

  def prefixed_clash_message(task, key, names) do
    """
    hearth.#{task}: `prefixed_ids:` for #{key} defines #{Enum.map_join(names, ", ", &"`#{&1}`")}, \
    which a generated operation function already uses. Rename the function in
    `functions:`, or the operation with `overrides: [operation_ids: …]`.
    """
  end

  def bad_overrides_message(task, key, detail) do
    """
    hearth.#{task}: the .hearth.exs entry for #{key} has malformed `overrides:`.

    #{detail}
    """
  end

  # `sources:` components that were shared and now split per source.
  def split_warning(key, splits) do
    names = Enum.map_join(splits, ", ", fn {{_section, name}, _keeper} -> name end)

    pairs =
      Enum.map_join(splits, ", ", fn {{section, name}, keeper} ->
        ~s|"#{section}/#{name}" => #{inspect(keeper)}|
      end)

    """
    #{key}: #{names} is no longer the same in every source, so each source's
    copy now carries its key — and shows as a rename in the drift. To keep
    the plain name for the source whose copy is unchanged, add to the entry
    in .hearth.exs:

        overrides: [shared: %{#{pairs}}]
    """
  end

  # Override entries that matched nothing in the source — usually a typo,
  # or an upstream rename. Reported, never fatal.
  def stale_overrides_notice(key, source, stale) do
    lines =
      Enum.map_join(stale, "\n", fn {kind, description} -> "  * #{kind} #{description}" end)

    """
    Overrides for #{key} that match nothing in #{source}:

    #{lines}

    Check them for typos, or for paths, operationIds and schemes renamed upstream.
    """
  end

  # Why `Hearth.Integration.Reprune` couldn't re-prune `key` from `source`.
  def reprune_message(task, key, source, reason, registry \\ %{})

  def reprune_message(task, key, _source, :no_tags, _registry) do
    """
    hearth.#{task}: #{key} is re-pruned from its source with the entry's
    `tags:`, but its .hearth.exs entry has none. Add one, e.g.

      #{key}: [module: …, source: …, tags: [Customers: :all]]
    """
  end

  def reprune_message(task, key, _source, {:bad_tags, detail}, _registry),
    do: bad_tags_message(task, key, detail)

  def reprune_message(task, key, _source, {:bad_overrides, detail}, _registry),
    do: bad_overrides_message(task, key, detail)

  def reprune_message(task, key, _source, {:bad_auth, name, available}, _registry),
    do: bad_auth_message(task, key, name, available)

  def reprune_message(task, key, _source, {:bad_prefixed_ids, detail}, _registry),
    do: bad_prefixed_ids_message(task, key, detail)

  def reprune_message(task, key, _source, :no_source, _registry) do
    """
    hearth.#{task}: #{key} is re-pruned from its source, but its
    .hearth.exs entry has no `source:` or `sources:`.
    """
  end

  def reprune_message(task, key, _source, :source_for_sources, _registry) do
    """
    hearth.#{task}: `--source` can't stand in for `sources:` — #{key} merges
    several specs. Point `sources:` in .hearth.exs at the ones to compare
    instead.
    """
  end

  def reprune_message(task, key, source, :empty_selection, _registry) do
    """
    hearth.#{task}: `tags:` for #{key} in .hearth.exs selects no operations in #{source}.
    """
  end

  def reprune_message(task, key, source, reason, registry),
    do: "hearth.#{task}: #{key}: " <> load_detail(source, reason, registry)

  # Why `Hearth.Integration.Load` couldn't load `source`.
  def load_message(task, source, reason, registry \\ %{}),
    do: "hearth.#{task}: " <> load_detail(source, reason, registry)

  defp load_detail(_source, {:in_source, source, reason}, registry),
    do: load_detail(source, reason, registry)

  defp load_detail(_source, {:merge, message}, _registry), do: message

  defp load_detail(source, :missing, _registry) do
    "file not found at #{inspect(source)}. " <>
      "Check the path is correct and relative to the project root."
  end

  defp load_detail(source, :unsupported, _registry) do
    "unsupported spec format for #{inspect(source)}. " <>
      "Supported extensions: .yaml, .yml, .json."
  end

  defp load_detail(source, {:decode, reason}, _registry),
    do: "failed to parse spec at #{source}.\n\n" <> format_reason(reason)

  defp load_detail(_source, {:fetch, url, reason}, _registry),
    do: "could not fetch #{url}: #{Hearth.Spec.Fetcher.describe_error(reason)}."

  defp load_detail(_source, {:registry, {:unknown_name, name}}, registry) do
    available = Enum.map_join(Hearth.Registry.list(registry), "\n", &"  * #{&1}")

    """
    no registry entry for `#{name}`.

    Available shortcuts — Hearth's, and any in .hearth.exs `registry:`:
    #{available}

    Pin a version with `name@version` (e.g. `stripe@latest`). If you
    have an OpenAPI spec elsewhere, pass it as a file path or URL
    instead.
    """
  end

  defp load_detail(_source, {:registry, {:unknown_version, name, version, available}}, _registry) do
    versions_block = Enum.map_join(available, "\n", &"  * #{name}@#{&1}")

    """
    registry shortcut `#{name}` has no version `#{version}`.

    Available versions:
    #{versions_block}
    """
  end

  defp load_detail(_source, {:invalid, message}, _registry), do: message

  defp verb(:regen), do: "regenerate"
  defp verb(:diff), do: "check"

  defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
  defp format_reason(reason), do: inspect(reason)
end
