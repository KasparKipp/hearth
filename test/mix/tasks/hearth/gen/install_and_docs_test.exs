defmodule Mix.Tasks.Hearth.Gen.InstallAndDocsTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: install gating and the consumer-facing docs.

  describe "install gating" do
    test "auto-runs install on a fresh project in test mode (no prompt)" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      assert_has_patch(igniter, ".formatter.exs", """
      + |  import_deps: [:hearth]
      """)

      refute Igniter.has_changes?(igniter, ["config/config.exs"])
    end

    test "is silent on already-installed projects" do
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

      igniter = Igniter.compose_task(project, "hearth.gen", ["stripe"])

      assert_unchanged(igniter, ".formatter.exs")

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
    test "notice does not point consumers at Hearth's internal docs" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      refute notice_text(igniter) =~ "AGENTS.md"
      refute notice_text(igniter) =~ "CLAUDE.md"
    end

    test "long_doc does not leak internal step numbers or docs" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      refute doc =~ "AGENTS.md"
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
      assert doc =~ "--no-domain"
      assert doc =~ "--tag"
      assert doc =~ "--n-operations"
      assert doc =~ "--list"
      assert doc =~ "--yes"
    end

    test "long_doc does not advertise --refresh, which has no fetcher behind it" do
      refute Mix.Tasks.Hearth.Gen.Docs.long_doc() =~ "--refresh"
    end

    test "--refresh is not an accepted option" do
      schema = Mix.Tasks.Hearth.Gen.info([], nil).schema
      refute Keyword.has_key?(schema, :refresh)
    end

    test "long_doc says only file sources generate code today" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      assert doc =~ "Only local file sources generate code today"
      refute doc =~ "Required for file and URL sources"
    end

    test "long_doc --list text covers file sources" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      refute doc =~ "Non-registry sources"
      assert doc =~ "mix hearth.gen priv/specs/petstore.yaml --list"
    end

    test "long_doc pipeline status lists every generated artifact and regen" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      assert doc =~ "external integration test"
      assert doc =~ "pruned spec"
      assert doc =~ "mix hearth.regen"
    end

    test "long_doc registry example uses a real name, not a placeholder" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()

      # `<name>` is only acceptable in --list usage hints (`mix hearth.gen
      # <name> --list`). It should never appear as a copy-paste-ready
      # generation example, which would tempt users to literally type
      # `<name>` and have nothing resolve.
      refute doc =~ ~r/mix hearth\.gen <name>$/m
      refute doc =~ ~r/mix hearth\.gen <name>\s+--integration/
      assert doc =~ ~r/mix hearth\.gen stripe/
    end

    test "long_doc lists available registry shortcuts" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()
      assert doc =~ "Registry shortcuts"
      assert doc =~ "Currently available"
      assert doc =~ "stripe"
    end

    test "long_doc points at --list for version discovery instead of stale claims" do
      doc = Mix.Tasks.Hearth.Gen.Docs.long_doc()

      # The old wording claimed historic versions were absent — directly
      # contradicted by `mix hearth.gen stripe --list`.
      refute doc =~ "until then only `@latest` is available"
      refute doc =~ "Historic versions are added to the registry"

      assert doc =~ "mix hearth.gen\n      <name> --list" or
               doc =~ "mix hearth.gen <name> --list"
    end
  end
end
