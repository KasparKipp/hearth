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

    test "file source emits a file-specific notice" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml"])

      notice = notice_text(igniter)
      assert notice =~ "Source recognized: file"
      assert notice =~ "priv/specs/petstore.yaml"
      assert notice =~ "YAML/JSON decode"
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

  describe "no side effects yet" do
    test "URL source does not modify any project files" do
      test_project()
      |> Igniter.compose_task("hearth.gen", ["https://example.com/openapi.json"])
      |> assert_unchanged()
    end

    test "file source does not modify any project files" do
      test_project()
      |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml"])
      |> assert_unchanged()
    end

    test "registry source does not modify any project files" do
      test_project()
      |> Igniter.compose_task("hearth.gen", ["stripe"])
      |> assert_unchanged()
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
  end
end
