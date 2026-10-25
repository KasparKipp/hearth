defmodule Hearth.Gen.Messages do
  @moduledoc false

  # Every multi-line user-facing text `mix hearth.gen` prints — notices,
  # issues, the registry and tag-discovery listings. Pure: strings in,
  # strings out. Kept out of the task module so the task reads as the
  # pipeline it is.

  alias Hearth.Spec.Operation

  def format_shortcuts do
    shortcuts = Enum.map_join(Hearth.Registry.list(), "\n", &"  * #{&1}")

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
    formatter import and :hearth_domains config. Run install now?
    """
  end

  def url_notice(url) do
    """
    Source recognized: URL.

        #{url}

    Next pipeline stage: HTTP fetch (Req-based, with on-disk cache under
    `priv/hearth/cache/<sha256>/`). Not yet wired — when ready, this
    command will fetch and cache the spec before decoding it.
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

  def generated_notice(path, spec, operations, selected, layers, wired) do
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
    Tests stub it with the generated Mox mock. Set the credential in config.
    """
  end

  def integration_exists_message(layer1, existing) do
    files = Enum.map_join(existing, "\n", &"  * #{&1}")

    """
    hearth.gen: #{inspect(layer1)} already exists.

    These generated files are present:

    #{files}

    `mix hearth.gen` only creates new integrations — it will not
    overwrite. Use `mix hearth.regen #{inspect(layer1)}` to
    regenerate from the pruned spec, or delete all of the files
    above to start over.
    """
  end

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
    hearth.gen: --integration is required for a file source.

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

  def file_not_found_message(path) do
    "hearth.gen: file not found at #{inspect(path)}. " <>
      "Check the path is correct and relative to the project root."
  end

  def unsupported_format_message(path) do
    "hearth.gen: unsupported spec format for #{inspect(path)}. " <>
      "Supported extensions: .yaml, .yml, .json."
  end

  def decode_failed_message(path, reason) do
    "hearth.gen: failed to parse spec at #{path}.\n\n" <> format_reason(reason)
  end

  defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
  defp format_reason(reason), do: inspect(reason)

  def registry_hit_notice(entry) do
    %{
      name: name,
      version: version,
      resolved_version: resolved,
      url: url,
      integration: integration
    } = entry

    header =
      if version == resolved do
        "Source recognized: registry shorthand `#{name}@#{version}`."
      else
        "Source recognized: registry shorthand `#{name}@#{version}` " <>
          "(alias for `#{name}@#{resolved}`)."
      end

    """
    #{header}

    Resolved to:
        #{url}

    Default integration name: #{integration} (override with --integration).

    Next pipeline stage: HTTP fetch (Req-based, with on-disk cache under
    `priv/hearth/cache/<sha256>/`). Not yet wired — when ready, this
    command will fetch and cache the spec before decoding it.
    """
  end

  def registry_unknown_name_message(name) do
    available = Enum.map_join(Hearth.Registry.list(), "\n", &"  * #{&1}")

    """
    hearth.gen: no registry entry for `#{name}`.

    Currently available shortcuts:
    #{available}

    Pin a version with `name@version` (e.g. `stripe@latest`). If you
    have an OpenAPI spec elsewhere, pass it as a file path or URL
    instead.
    """
  end

  def registry_unknown_version_message(name, version, available) do
    versions_block = Enum.map_join(available, "\n", &"  * #{name}@#{&1}")

    """
    hearth.gen: registry shortcut `#{name}` has no version `#{version}`.

    Available versions:
    #{versions_block}
    """
  end
end
