defmodule Mix.Tasks.Hearth.GenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  describe "source recognition" do
    test "URL source emits a URL-specific notice" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["https://example.com/openapi.json"])

      notice = notice_text(igniter)
      assert notice =~ "Source recognized: URL"
      assert notice =~ "https://example.com/openapi.json"
      assert notice =~ "HTTP fetch"
    end

    test "file source emits a file-specific notice when the file exists" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => "openapi: 3.0.0\n"})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml"])

      notice = notice_text(igniter)
      assert notice =~ "Source recognized: file"
      assert notice =~ "priv/specs/petstore.yaml"
      assert notice =~ "YAML/JSON decode"
    end

    test "file source halts with an issue when the file is missing" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["priv/specs/does-not-exist.yaml"])

      assert Enum.any?(
               igniter.issues,
               &String.contains?(&1, "file not found at \"priv/specs/does-not-exist.yaml\"")
             )

      refute notice_text(igniter) =~ "Source recognized: file"
    end

    test "registry source emits a registry-specific notice" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      notice = notice_text(igniter)
      assert notice =~ "Source recognized: registry shorthand `stripe`"
      assert notice =~ "registry lookup"
    end

    test "registry name is normalized to lowercase in the notice" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["STRIPE"])

      assert notice_text(igniter) =~ "`stripe`"
    end
  end

  describe "error paths" do
    test "missing source raises a useful error" do
      assert_raise ArgumentError, ~r/Required positional argument `source`/, fn ->
        test_project()
        |> Igniter.compose_task("hearth.gen", [])
      end
    end

    test "unclassifiable source records an issue" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["foo bar"])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "could not classify"))
    end
  end

  describe "install gating" do
    test "auto-runs install on a fresh project in test mode (no prompt)" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      assert_has_patch(igniter, ".formatter.exs", """
      + |  import_deps: [:hearth]
      """)

      assert_creates(igniter, "config/config.exs", """
      import Config
      config :test, hearth_domains: []
      """)
    end

    test "is silent on already-installed projects" do
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

      igniter = Igniter.compose_task(project, "hearth.gen", ["stripe"])

      assert_unchanged(igniter, [".formatter.exs", "config/config.exs"])

      # On an already-installed project we drop install's "already installed"
      # notice so consumers don't see redundant chatter when running gen.
      refute notice_text(igniter) =~ "already installed"
    end

    test "honours --yes for non-test invocations" do
      # Simulate a non-test-mode run: install is needed AND no test_mode auto-accept.
      # --yes should still allow install to compose without prompting.
      igniter =
        test_project()
        |> Map.update!(:assigns, &Map.put(&1, :test_mode?, false))
        |> Igniter.compose_task("hearth.gen", ["stripe", "--yes"])

      assert_has_patch(igniter, ".formatter.exs", """
      + |  import_deps: [:hearth]
      """)
    end
  end

  describe "consumer-facing docs" do
    test "notice does not point consumers at Hearth's internal CLAUDE.md" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      refute notice_text(igniter) =~ "CLAUDE.md"
    end

    test "long_doc does not leak internal step numbers or CLAUDE.md" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      refute doc =~ "CLAUDE.md"
      refute doc =~ ~r/step \d/i
    end

    test "long_doc has a pipeline-status section listing what works today" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      assert doc =~ "Pipeline status"
      assert doc =~ "Available now"
      assert doc =~ "Coming soon"
      assert doc =~ "source recognition"
    end

    test "long_doc documents every task option" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      assert doc =~ "## Options"
      assert doc =~ "--integration"
      assert doc =~ "--domain"
      assert doc =~ "--refresh"
      assert doc =~ "--yes"
    end

    test "long_doc no longer shows a copy-pasteable registry example that does not work" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      refute doc =~ ~r/mix hearth\.gen <name>/
      refute doc =~ ~r/mix hearth\.gen stripe\b/
    end
  end
end
