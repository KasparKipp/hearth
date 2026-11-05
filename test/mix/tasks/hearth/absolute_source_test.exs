defmodule Mix.Tasks.Hearth.AbsoluteSourceTest do
  use Hearth.TaskCase, async: true

  # A `source:` given as an absolute path, inside or outside the project.
  # Before writing, Igniter's format step globs
  # `<first path segment>/**/.formatter.exs` for every file in its Rewrite,
  # skipping only `..` paths. For an absolute path that's `/**`: the whole
  # disk, so `regen --sync` hangs. The step is skipped in test mode, so
  # these tests check what triggers it: no absolute path in the Rewrite.
  # (In test mode an absolute path fails sooner: `Igniter.exists?/2` makes
  # it relative to the project, but the read that follows doesn't.) So
  # these pin one design: an absolute path is made relative to the project,
  # through `..` when outside it, before it reaches the Rewrite.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @layer1 "lib/test/integrations/petstore.ex"

  # Outside the project: Igniter's test files key it as `../specs/…`.
  @outside_key "../specs/petstore.yaml"
  @outside Path.expand(@outside_key)
  @inside Path.expand("priv/specs/petstore.yaml")

  defp project do
    test_project(
      files: %{
        "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
        @outside_key => @petstore_3_0_yaml
      }
    )
  end

  # gen with `--tag pets:listPets` from the project's copy, applied.
  defp generated do
    project()
    |> Igniter.compose_task("hearth.gen", [
      "priv/specs/petstore.yaml",
      "--integration",
      "Petstore",
      "--tag",
      "pets:listPets"
    ])
    |> apply_igniter!()
  end

  defp point_at(igniter, source, fields \\ []) do
    igniter
    |> Hearth.Config.Project.put_fields(:petstore, [source: source] ++ fields)
    |> apply_igniter!()
  end

  # Replaces `.hearth.exs` with one petstore entry selecting every pets
  # operation, plus `fields` and `top` (other top-level keys), applied.
  defp set_entry(igniter, fields, top \\ []) do
    entry = [module: Test.Integrations.Petstore, tags: [pets: :all]] ++ fields
    exs = inspect(top ++ [integrations: [petstore: entry]], limit: :infinity)

    igniter
    |> Igniter.create_new_file(".hearth.exs", exs, on_exists: :overwrite)
    |> apply_igniter!()
  end

  defp absolute_paths(igniter) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(Path.type(&1) == :absolute))
  end

  defp pruned_paths(igniter) do
    igniter
    |> created_file("priv/hearth/petstore.yaml")
    |> YamlElixir.read_from_string!()
    |> Map.fetch!("paths")
    |> Enum.flat_map(fn {path, ops} -> Enum.map(Map.keys(ops), &"#{&1} #{path}") end)
    |> Enum.sort()
  end

  test "gen reads a spec outside the project" do
    igniter =
      project()
      |> Igniter.compose_task("hearth.gen", [@outside, "--integration", "Petstore"])

    assert igniter.issues == []
    assert_creates(igniter, @layer1)
    assert absolute_paths(igniter) == []
  end

  test "gen records the source as given, and regen after gen is a no-op" do
    igniter =
      project()
      |> Igniter.compose_task("hearth.gen", [@outside, "--integration", "Petstore"])
      |> apply_igniter!()

    {:ok, [petstore: entry]} =
      igniter
      |> Igniter.include_existing_file(".hearth.exs")
      |> created_file(".hearth.exs")
      |> Hearth.Config.parse()

    assert entry[:source] == @outside

    igniter
    |> Igniter.compose_task("hearth.regen", ["petstore"])
    |> assert_unchanged()
  end

  test "regen --sync re-prunes from a source outside the project" do
    igniter =
      generated()
      |> point_at(@outside, tags: [pets: :all])
      |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])

    assert igniter.issues == []
    assert pruned_paths(igniter) == ["get /pets", "get /pets/{petId}", "post /pets"]
    assert absolute_paths(igniter) == []
  end

  test "regen --sync takes an absolute path inside the project too" do
    igniter =
      generated()
      |> point_at(@inside, tags: [pets: :all])
      |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])

    assert igniter.issues == []
    assert pruned_paths(igniter) == ["get /pets", "get /pets/{petId}", "post /pets"]
    assert absolute_paths(igniter) == []
  end

  test "regen --sync takes a relative ../ path, as before" do
    igniter =
      generated()
      |> point_at(@outside_key, tags: [pets: :all])
      |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])

    assert igniter.issues == []
    assert pruned_paths(igniter) == ["get /pets", "get /pets/{petId}", "post /pets"]
  end

  test "regen --sync reads an absolute path in sources:" do
    igniter =
      generated()
      |> set_entry(sources: [pets: @outside])
      |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])

    assert igniter.issues == []
    # A merge moves each source's server path (`/v1`) into its paths.
    assert pruned_paths(igniter) == ["get /v1/pets", "get /v1/pets/{petId}", "post /v1/pets"]
    assert absolute_paths(igniter) == []
  end

  test "regen --sync reads a .hearth.exs registry shortcut with an absolute location" do
    igniter =
      generated()
      |> set_entry([source: "pets@1"], registry: %{"pets" => %{"1" => @outside}})
      |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])

    assert igniter.issues == []
    assert pruned_paths(igniter) == ["get /pets", "get /pets/{petId}", "post /pets"]
    assert absolute_paths(igniter) == []
  end

  test "diff --source takes an absolute path" do
    igniter =
      generated()
      |> Igniter.compose_task("hearth.diff", ["petstore", "--source", @outside])

    # The full spec has operations the pruned one doesn't select: not drift.
    assert igniter.issues == []
    assert absolute_paths(igniter) == []
  end

  test "diff compares with a source outside the project" do
    igniter =
      generated()
      |> point_at(@outside)
      |> Igniter.compose_task("hearth.diff", ["petstore"])

    assert igniter.issues == []
    assert absolute_paths(igniter) == []
  end
end
