defmodule Hearth.Diff.Messages do
  @moduledoc false

  # Every user-facing text `mix hearth.diff` prints: the drift report
  # for one integration, and the task's own halts. Pure: strings in,
  # strings out.

  alias Hearth.Spec.Drift
  alias Hearth.Spec.Operation

  # `source_state` — how the compared source relates to the entry's
  # `source_sha256`: `:unchanged`, `:changed`, or `nil` when there's
  # nothing recorded. `entry_source?` — whether `source` is the entry's
  # own `source:` (or a `--source` candidate).
  def report(key, source, changes, unlisted, source_state, entry_source?) do
    [
      header(key, source, changes),
      source_line(source_state, changes, entry_source?),
      section("Operations", Enum.filter(changes, &(&1.area == :operation))),
      section("Schemas", Enum.filter(changes, &(&1.area == :schema))),
      unlisted_section(unlisted),
      footer(key, source, changes, entry_source?)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp header(key, source, []), do: "hearth.diff: #{key}: no drift against #{source}."
  defp header(key, source, _changes), do: "hearth.diff: #{key} has drifted from #{source}."

  defp source_line(nil, _changes, _entry_source?), do: nil

  defp source_line(:changed, _changes, false),
    do: "It differs from the source recorded at the last gen or sync."

  defp source_line(:unchanged, _changes, false),
    do: "It is identical to the source recorded at the last gen or sync."

  defp source_line(:changed, _changes, true), do: "The source changed since the last gen or sync."

  defp source_line(:unchanged, [], true),
    do: "The source is unchanged since the last gen or sync."

  defp source_line(:unchanged, _changes, true) do
    "The source is unchanged since the last gen or sync, so the drift comes " <>
      "from local edits — to `tags:` or to the pruned spec."
  end

  defp section(_title, []), do: nil

  defp section(title, changes) do
    "#{title}:\n" <> Enum.map_join(changes, "\n", &"  #{Drift.format(&1)}")
  end

  defp unlisted_section([]), do: nil

  defp unlisted_section(operations) do
    lines = Enum.map_join(operations, "\n", &"  · #{operation_label(&1)}")

    """
    New upstream operations not selected by `tags:` — list them under
    `include:` or `exclude:` to decide:

    #{lines}\
    """
  end

  defp operation_label(%Operation{method: method, path: path} = op) do
    case op.operation_id do
      nil -> "#{method} #{path}"
      id -> "#{method} #{path} (#{id})"
    end
  end

  defp footer(_key, _source, [], _entry_source?), do: nil

  defp footer(key, source, changes, entry_source?) do
    breaking = Enum.count(changes, & &1.breaking?)
    count = "#{length(changes)} #{if length(changes) == 1, do: "change", else: "changes"}"

    tally =
      if breaking == 0, do: "#{count}, none breaking.", else: "#{count} (#{breaking} breaking)."

    apply =
      if entry_source?,
        do: "Apply them with:",
        else: "To apply them, point `source:` at #{source} in .hearth.exs and run:"

    "#{tally} #{apply}\n\n  mix hearth.regen #{key} --sync"
  end

  def missing_spec_message(key, spec_path) do
    """
    hearth.diff: no pruned spec for #{key} at #{spec_path}. Re-create it
    from the source:

      mix hearth.regen #{key} --sync
    """
  end

  def bad_fail_on_message(value) do
    """
    hearth.diff: --fail-on must be `any` or `breaking`, got #{inspect(value)}.
    """
  end

  def source_needs_one_message do
    """
    hearth.diff: --source compares exactly one integration against another spec.

      mix hearth.diff stripe --source priv/specs/stripe-2026-10.yaml
    """
  end

  def failed_to_parse_message(spec_path, reason) do
    "hearth.diff: failed to parse #{spec_path}: #{format_reason(reason)}"
  end

  defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
  defp format_reason(reason), do: inspect(reason)
end
