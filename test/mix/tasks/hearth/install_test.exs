defmodule Mix.Tasks.Hearth.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  describe "mix igniter.install hearth" do
    # `igniter.install` reads these from the installer's info/2 and sets
    # them on the dep it adds — Hearth is a dev/test-time generator.
    test "adds the dep as only: [:dev, :test], runtime: false" do
      info = Mix.Tasks.Hearth.Install.info([], nil)

      assert info.only == [:dev, :test]
      assert info.dep_opts == [runtime: false]
    end
  end

  describe "formatter" do
    test "adds :hearth to import_deps in .formatter.exs" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:hearth]
      """)
    end
  end

  describe "config" do
    test "writes no config" do
      igniter = Igniter.compose_task(test_project(), "hearth.install", [])

      refute Igniter.has_changes?(igniter, ["config/config.exs"])
    end

    test "leaves an existing :hearth_domains entry alone" do
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, :hearth_domains, [MyApp.Billing.Stripe]
          """
        }
      )
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged("config/config.exs")
    end
  end

  describe "first-install notice" do
    setup do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.install", [])

      %{notice: notice_text(igniter)}
    end

    test "lists the files that were modified", %{notice: notice} do
      assert notice =~ "Modified:"
      assert notice =~ ".formatter.exs"
      refute notice =~ "config/config.exs"
    end

    test "stamps the Hearth version", %{notice: notice} do
      assert notice =~ ~r/Hearth v\S+/
    end

    test "points at mix hearth.gen with a spec file", %{notice: notice} do
      assert notice =~ "mix hearth.gen"
      assert notice =~ "OpenAPI"
    end

    test "does not mention :hearth_domains", %{notice: notice} do
      refute notice =~ "hearth_domains"
    end

    test "does not reference unreleased commands", %{notice: notice} do
      refute notice =~ "mix hearth.regen"
    end
  end

  describe "repeat-install notice" do
    test "emits a short already-installed notice when nothing changed" do
      project =
        test_project(
          files: %{
            ".formatter.exs" => """
            [
              inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
              import_deps: [:hearth]
            ]
            """
          }
        )

      notice = project |> Igniter.compose_task("hearth.install", []) |> notice_text()

      assert notice =~ ~r/Hearth v\S+ already installed/
      refute notice =~ "Modified"
    end
  end

  describe "consumer-facing docs" do
    test "long_doc cross-links to hearth.gen auto-invocation" do
      doc = Mix.Tasks.Hearth.Install.Docs.long_doc()
      assert doc =~ "hearth.gen"
    end
  end

  describe "idempotency" do
    test "running twice in a row is a no-op" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged()
    end
  end
end
