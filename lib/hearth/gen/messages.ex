defmodule Hearth.Gen.Messages do
  @moduledoc false

  # Every multi-line user-facing text `mix hearth.gen` prints — notices,
  # issues, the registry and tag-discovery listings. Pure: strings in,
  # strings out. Kept out of the task module so the task reads as the
  # pipeline it is.

  alias Hearth.Spec.Operation

  def format_shortcuts(registry \\ %{}) do
    shortcuts =
      Enum.map_join(Hearth.Registry.list(registry), "\n", fn name ->
        if Map.has_key?(registry, name), do: "  * #{name} (.hearth.exs)", else: "  * #{name}"
      end)

    """
    Hearth shortcuts:

    #{shortcuts}

    Pass a shortcut to mix hearth.gen, e.g. `mix hearth.gen stripe`.
    Run `mix hearth.gen <name> --list` to see versions for a shortcut.
    """
  end

  def format_versions(name, versions) do
    list = Enum.map_join(versions, "\n", &"  * #{&1}")

    """
    #{name} versions:

    #{list}

    Pin with `name@version`, e.g. `mix hearth.gen #{name}@#{List.last(versions)}`.
    Bare `mix hearth.gen #{name}` resolves to @latest.
    """
  end

  def missing_source_message do
    """
    hearth.gen: pass a source to generate from.

      mix hearth.gen <source>           # see source modes below
      mix hearth.gen --list             # show registered shortcuts
      mix hearth.gen <name> --list      # show versions for a shortcut

    Source modes:
      * file:     priv/specs/<api>.yaml
      * URL:      https://example.com/openapi.json
      * registry: stripe   (run with --list for the full set)

    Run `mix help hearth.gen` for full options.
    """
  end

  def install_prompt do
    """
    hearth.gen needs `mix hearth.install` to set up your project's
    formatter import. Run install now?
    """
  end

  defp summarize(spec) when is_map(spec) do
    %{
      title: get_in(spec, ["info", "title"]) || "<untitled>",
      info_version: get_in(spec, ["info", "version"]) || "<unversioned>",
      openapi: Map.get(spec, "openapi", "<unknown>"),
      paths: paths_count(spec)
    }
  end

  defp summarize(_), do: %{title: "<not a map>", info_version: "?", openapi: "?", paths: 0}

  defp paths_count(spec) do
    case Map.get(spec, "paths") do
      paths when is_map(paths) -> map_size(paths)
      _ -> 0
    end
  end

  def generated_notice(path, spec, operations, selected, layers, wired, credential) do
    summary = summarize(spec)
    tag_count = selected |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> length()

    file_lines =
      Enum.map_join(layers, "\n", fn {module, location, label} ->
        "* generating #{location}\n      #{inspect(module)} — #{label}"
      end)

    wired_lines = Enum.map_join(wired, "\n", &"* wiring #{&1}")

    """
    Spec loaded from #{path}.

        #{summary.title} (info.version #{summary.info_version}, OpenAPI #{summary.openapi})

    Selected #{length(selected)} of #{length(operations)} operations \
    across #{tag_count} #{pluralize("tag", tag_count)}.

    #{file_lines}

    #{wired_lines}

    Business logic calls the behaviour directly — `<Integration>Api.<operation>(...)`.
    Tests stub it with the generated Mox mock.#{credential}
    """
  end

  # The last line of the generated notice: where the credential comes
  # from, or why there isn't one.
  def credential_hint(:none, _names), do: ""

  def credential_hint({:unsupported, type}, names) do
    "\n\nAuth isn't wired: Hearth doesn't support the spec's #{type} scheme\n" <>
      "(see the TODO in #{inspect(names.layer1)}). The entry's `auth:` in\n" <>
      ".hearth.exs lists the spec's schemes."
  end

  def credential_hint(_auth, names) do
    env_var = env_var(names, :api_key)

    "\n\nSet the credential: the #{env_var} environment variable (read in\n" <>
      "config/runtime.exs), or `api_key:` in #{inspect(names.layer1)}'s config."
  end

  def headers_hint([], _names), do: ""

  def headers_hint(headers, names) do
    vars = Enum.map_join(headers, ", ", fn {_name, key} -> env_var(names, key) end)

    "\n\nSet the headers: #{vars} (read in config/runtime.exs), or the\n" <>
      "matching keys in #{inspect(names.layer1)}'s config."
  end

  # Required header params every selected operation takes that nothing
  # sends yet.
  def headers_notice(names, suggestions) do
    pairs =
      Enum.map_join(suggestions, ", ", fn {name, key} -> "#{inspect(name)}: #{inspect(key)}" end)

    """
    Every operation requires #{Enum.map_join(suggestions, ", ", &elem(&1, 0))}, which nothing sends yet.
    To send #{if length(suggestions) == 1, do: "it", else: "them"} on every call, add to the #{Hearth.Config.key(names.integration)} entry in .hearth.exs
    and run `mix hearth.regen #{Hearth.Config.key(names.integration)}`:

        headers: [#{pairs}]
    """
  end

  defp env_var(names, key),
    do: String.upcase(Macro.underscore(names.integration) <> "_" <> Atom.to_string(key))

  # Which prefixes each `prefixed_ids:` function works for.
  def prefixed_notice(layer2, pairs, covered) do
    lines =
      Enum.map_join(pairs, "\n", fn {name, prefixes} ->
        "* #{inspect(layer2)}.#{name}/2 — #{Enum.join(prefixes, ", ")}"
      end)

    """
    Prefixed-id functions, and the id prefixes each one works for:

    #{lines}
    #{covered_section(covered)}\
    """
  end

  defp covered_section([]), do: ""

  defp covered_section(covered) do
    lines =
      Enum.map_join(covered, "\n", fn {op, name} ->
        label = if op.operation_id, do: " (#{op.operation_id})", else: ""
        "* #{op.method} #{op.path}#{label} — through #{name}/2"
      end)

    """

    Selected, but reached through those functions instead of their own:

    #{lines}
    """
  end

  def integration_exists_message(layer1, existing) do
    files = Enum.map_join(existing, "\n", &"  * #{&1}")

    """
    hearth.gen: #{inspect(layer1)} already exists.

    These generated files are present:

    #{files}

    `mix hearth.gen` only creates new integrations — it will not
    overwrite. Use `mix hearth.regen #{regen_name(layer1)}` to
    regenerate from the pruned spec, or delete all of the files
    above to start over.
    """
  end

  # The integration name `regen` takes: Layer 1's last segment.
  defp regen_name(layer1), do: layer1 |> Module.split() |> List.last() |> Macro.underscore()

  def bad_segment(flag, value) do
    """
    hearth.gen: #{flag} #{inspect(value)} is not a valid module name.

    It must be a single Elixir alias segment — a letter followed by
    letters or digits, with no spaces or dots (e.g. `Stripe`,
    `SendGrid`). snake_case is accepted too (`send_grid` → `SendGrid`).
    """
  end

  def missing_integration_message(path) do
    """
    hearth.gen: --integration is required for a file or URL source.

      mix hearth.gen #{path} --integration <Name>

    <Name> becomes the integration's module name — `--integration Stripe`
    generates the behaviour at App.Integrations.Stripe.StripeApi.
    """
  end

  # Builds the tag-discovery text: a header, the per-tag operationId
  # listing, and a fully-expanded subset command — every tag with
  # every one of its operationIds spelled out, one `--tag` per line.
  # The user copies it and deletes whole lines or individual
  # operationIds; nothing has to be looked up, no intent is assumed.
  #
  # Shared by the `--n-operations` gate (pass `:limit`) and
  # `mix hearth.gen <file> --list` (pass `limit: nil`).
  def tag_discovery(operations, opts) do
    source = opts[:source]
    integration = opts[:integration] || "<Name>"
    index = Operation.tag_index(operations)
    total = length(operations)
    tag_count = index |> Map.keys() |> Enum.count(&is_binary/1)

    """
    #{discovery_header(total, tag_count, opts[:limit])}

    Tags in this spec — pass a subset with one or more --tag flags:

    #{format_tag_listing(index)}

    Generate a subset — copy this and delete the --tag lines or the
    operationIds you don't want:

    #{subset_command(source, integration, index)}

    Or generate everything:
      mix hearth.gen #{source} --integration #{integration} --n-operations #{total}
    """
  end

  defp discovery_header(total, tag_count, nil) do
    "This spec has #{total} operations across #{tag_count} #{pluralize("tag", tag_count)}."
  end

  defp discovery_header(total, _tag_count, limit) do
    "This spec has #{total} operations, above the --n-operations limit (#{limit})."
  end

  defp format_tag_listing(index) do
    index
    |> Enum.sort_by(&tag_sort_key/1)
    |> Enum.map_join("\n", &tag_listing_line/1)
  end

  defp subset_command(source, integration, index) do
    tag_lines =
      index
      |> Enum.filter(fn {tag, _ops} -> is_binary(tag) end)
      |> Enum.sort_by(fn {tag, _ops} -> tag end)
      |> Enum.map(fn {tag, ops} ->
        ids = Enum.map_join(ops, ",", & &1.id)
        ~s(    --tag "#{tag}:#{ids}")
      end)

    ["  mix hearth.gen #{source} --integration #{integration}" | tag_lines]
    |> Enum.join(" \\\n")
  end

  defp tag_sort_key({:untagged, _ops}), do: {1, ""}
  defp tag_sort_key({tag, _ops}), do: {0, tag}

  defp tag_listing_line({tag, ops}) do
    ids = Enum.map_join(ops, ", ", &":#{&1.id}")
    "  #{tag_label(tag)}: [#{ids}]"
  end

  defp tag_label(:untagged), do: ":untagged"
  defp tag_label(tag) when is_binary(tag), do: inspect(tag)

  def pluralize(word, 1), do: word
  def pluralize(word, _count), do: word <> "s"

  # A registry shortcut was resolved: which entry, and where it pointed.
  def resolved_notice(source, entry) do
    alias_note =
      if entry.version == entry.resolved_version,
        do: "",
        else: " (alias for `#{entry.name}@#{entry.resolved_version}`)"

    local_note = if entry.local?, do: " from .hearth.exs", else: ""

    """
    Resolved `#{source}`#{alias_note}#{local_note} to:
        #{entry.location}
    """
  end
end
