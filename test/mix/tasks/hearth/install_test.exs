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

  describe ":hearth_domains config" do
    test "initializes :hearth_domains to [] when unset" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_creates("config/config.exs", """
      import Config
      config :test, hearth_domains: []
      """)
    end

    test "preserves an explicit false opt-out on re-run" do
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, :hearth_domains, false
          """
        }
      )
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged("config/config.exs")
    end

    test "preserves a populated :hearth_domains list on re-run" do
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

    test "explains :hearth_domains and how to populate it", %{notice: notice} do
      assert notice =~ ":hearth_domains"
      assert notice =~ "MyApp.Billing.Stripe" || notice =~ "Test.Billing.Stripe"
    end

    test "lists the files that were modified", %{notice: notice} do
      assert notice =~ "Modified:"
      assert notice =~ ".formatter.exs"
      assert notice =~ "config/config.exs"
    end

    test "stamps the Hearth version", %{notice: notice} do
      assert notice =~ ~r/Hearth v\S+/
    end

    test "points at mix hearth.gen with a spec file", %{notice: notice} do
      assert notice =~ "mix hearth.gen"
      assert notice =~ "OpenAPI"
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
            "config/config.exs" => """
            import Config
            config :test, hearth_domains: []
            """,
            ".formatter.exs" => """
            [
              inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
              import_deps: [:hearth]
            ]
            """
          }
        )

      igniter = Igniter.compose_task(project, "hearth.install", [])
      notice = notice_text(igniter)

      assert notice =~ ~r/Hearth v\S+ already installed/
      refute notice =~ ":hearth_domains"
      refute notice =~ "Modified"
    end

    test "emits a short summary when only some files changed on re-run" do
      project =
        test_project(
          files: %{
            "config/config.exs" => """
            import Config
            config :test, hearth_domains: [MyApp.Billing.Stripe]
            """
          }
        )

      igniter = Igniter.compose_task(project, "hearth.install", [])
      notice = notice_text(igniter)

      assert notice =~ "Modified: .formatter.exs"
      refute notice =~ ":hearth_domains"
    end

    test "honors a false opt-out without re-explaining :hearth_domains" do
      igniter =
        test_project(
          files: %{
            "config/config.exs" => """
            import Config
            config :test, :hearth_domains, false
            """,
            ".formatter.exs" => """
            [
              inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
              import_deps: [:hearth]
            ]
            """
          }
        )
        |> Igniter.compose_task("hearth.install", [])

      refute notice_text(igniter) =~ "Add integrations"
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
