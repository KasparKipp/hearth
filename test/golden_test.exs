defmodule Hearth.GoldenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # Golden-file snapshots of everything `mix hearth.gen` writes for each
  # fixture spec: the generated code, the pruned spec, and every patched
  # project file. Snapshots live at `test/generated/<case>/<path>.golden`
  # — the suffix keeps `mix test`, `mix format`, and credo away from the
  # generated `*_test.exs` / `.ex` files.
  #
  # A change to generator output fails here. When the change is
  # intended, regenerate and review the snapshot diff:
  #
  #     HEARTH_UPDATE_GOLDEN=1 mix test test/golden_test.exs

  @cases [
    {"petstore", "test/fixtures/specs/petstore-3.0.yaml", "Petstore"},
    {"tictactoe", "test/fixtures/specs/tictactoe-3.1.yaml", "Tictactoe"},
    {"keyed", "test/fixtures/specs/keyed-3.0.yaml", "Keyed"}
  ]

  @update? System.get_env("HEARTH_UPDATE_GOLDEN") == "1"

  for {name, fixture, integration} <- @cases do
    test "#{name}: generated output matches the golden files" do
      generated = generate(unquote(fixture), unquote(integration))
      dir = Path.join("test/generated", unquote(name))

      if @update?, do: write_golden(dir, generated)

      assert_golden(dir, generated)
    end
  end

  # Runs `mix hearth.gen` on the fixture in a fresh test project and
  # returns `%{path => content}` for every file the task created or
  # changed.
  defp generate(fixture, integration) do
    spec_path = Path.join("priv/specs", Path.basename(fixture))

    igniter =
      test_project(files: %{spec_path => File.read!(fixture)})
      |> Igniter.compose_task("hearth.gen", [spec_path, "--integration", integration])

    assert igniter.issues == []

    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.filter(&Rewrite.Source.updated?/1)
    |> Map.new(&{&1.path, Rewrite.Source.get(&1, :content)})
  end

  defp write_golden(dir, generated) do
    File.rm_rf!(dir)

    Enum.each(generated, fn {path, content} ->
      golden = golden_path(dir, path)
      File.mkdir_p!(Path.dirname(golden))
      File.write!(golden, content)
    end)
  end

  defp assert_golden(dir, generated) do
    golden_files =
      dir
      |> Path.join("**/*.golden")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&(&1 |> Path.relative_to(dir) |> String.replace_suffix(".golden", "")))
      |> Enum.sort()

    assert golden_files == generated |> Map.keys() |> Enum.sort(),
           "the set of generated files differs from #{dir} — " <> update_hint()

    for {path, content} <- generated do
      assert content == File.read!(golden_path(dir, path)),
             "#{path} drifted from its golden file — " <> update_hint()
    end
  end

  defp golden_path(dir, path), do: Path.join(dir, path <> ".golden")

  defp update_hint do
    "if the change is intended, run `HEARTH_UPDATE_GOLDEN=1 mix test " <>
      "test/golden_test.exs` and review the snapshot diff."
  end
end
