defmodule Mix.Tasks.Hearth.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "adds :hearth to import_deps in .formatter.exs" do
    test_project()
    |> Igniter.compose_task("hearth.install", [])
    |> assert_has_patch(".formatter.exs", """
    + |  import_deps: [:hearth]
    """)
  end

  test "is idempotent" do
    test_project()
    |> Igniter.compose_task("hearth.install", [])
    |> apply_igniter!()
    |> Igniter.compose_task("hearth.install", [])
    |> assert_unchanged()
  end
end
