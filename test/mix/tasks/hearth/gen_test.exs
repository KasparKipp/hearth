defmodule Mix.Tasks.Hearth.GenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Igniter.Test

  # Fixtures are read at compile time and threaded through Igniter's virtual
  # fs via `test_project(files: %{...})` — in test mode `Igniter.exists?/2`
  # only consults the virtual fs, never real disk.
  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @petstore_3_0_json File.read!("test/fixtures/specs/petstore-3.0.json")
  @tictactoe_3_1_yaml File.read!("test/fixtures/specs/tictactoe-3.1.yaml")

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

    test "YAML file source decodes and summarizes the spec" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml"])

      notice = notice_text(igniter)
      assert notice =~ "Spec loaded from priv/specs/petstore.yaml"
      assert notice =~ "Swagger Petstore"
      assert notice =~ "OpenAPI 3.0.0"
      assert notice =~ ~r/\d+ paths/
      assert notice =~ ~r/\d+ operations/
      assert notice =~ "code generation"
    end

    test "JSON file source decodes and summarizes the spec" do
      igniter =
        test_project(files: %{"priv/specs/petstore.json" => @petstore_3_0_json})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.json"])

      notice = notice_text(igniter)
      assert notice =~ "Spec loaded"
      assert notice =~ "Swagger Petstore"
    end

    test "OAS 3.1 file source decodes correctly" do
      igniter =
        test_project(files: %{"priv/specs/tictactoe.yaml" => @tictactoe_3_1_yaml})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/tictactoe.yaml"])

      notice = notice_text(igniter)
      assert notice =~ "Tic Tac Toe"
      assert notice =~ "OpenAPI 3.1.0"
    end

    test "file source halts with an issue when the file is missing" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["priv/specs/does-not-exist.yaml"])

      assert Enum.any?(
               igniter.issues,
               &String.contains?(&1, "file not found at \"priv/specs/does-not-exist.yaml\"")
             )

      refute notice_text(igniter) =~ "Spec loaded"
    end

    test "file source with unsupported extension halts with a clear issue" do
      igniter =
        test_project(files: %{"priv/specs/foo.xml" => "<oas/>"})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/foo.xml"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "unsupported spec format") and
                 String.contains?(issue, "foo.xml") and
                 String.contains?(issue, ".yaml")
             end)
    end

    test "file source with malformed YAML halts with a parse-error issue" do
      igniter =
        test_project(files: %{"priv/specs/broken.yaml" => "[this: is: not: yaml"})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/broken.yaml"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "failed to parse spec") and
                 String.contains?(issue, "broken.yaml")
             end)
    end

    test "bare shortcut resolves to @latest" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])

      notice = notice_text(igniter)
      assert notice =~ "Source recognized: registry shorthand `stripe@latest`"
      assert notice =~ "Resolved to:"
      assert notice =~ "raw.githubusercontent.com/stripe"
      assert notice =~ "Default integration name: Stripe"
      assert notice =~ "HTTP fetch"
    end

    test "explicit @latest is equivalent to bare shortcut" do
      bare =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe"])
        |> notice_text()

      pinned =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@latest"])
        |> notice_text()

      assert bare == pinned
    end

    test "registry name is normalized to lowercase before lookup" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["STRIPE"])

      assert notice_text(igniter) =~ "`stripe@latest`"
      assert notice_text(igniter) =~ "Resolved to:"
    end

    test "unknown registry name halts with the available shortcuts" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["unknownvendor"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "no registry entry for `unknownvendor`") and
                 String.contains?(issue, "stripe")
             end)

      refute notice_text(igniter) =~ "Resolved to:"
    end

    test "unknown version halts with the available versions for that shortcut" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@2099-01-01"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "registry shortcut `stripe` has no version `2099-01-01`") and
                 String.contains?(issue, "stripe@latest")
             end)
    end

    test "alias notice surfaces the alias relationship in the header" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@dahlia"])

      notice = notice_text(igniter)

      assert notice =~
               "registry shorthand `stripe@dahlia` (alias for `stripe@2026-04-22.dahlia`)"

      assert notice =~ "Resolved to:"
      assert notice =~ "raw.githubusercontent.com/stripe"
    end

    test "@latest is a canonical entry with its own floating URL, no alias annotation" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@latest"])

      notice = notice_text(igniter)
      assert notice =~ "registry shorthand `stripe@latest`."
      refute notice =~ "alias for"
      assert notice =~ "refs/heads/master"
    end

    test "@2026-04-22.dahlia is a canonical entry with the tagged URL" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@2026-04-22.dahlia"])

      notice = notice_text(igniter)
      assert notice =~ "registry shorthand `stripe@2026-04-22.dahlia`."
      refute notice =~ "alias for"
      assert notice =~ "v2266"
    end
  end

  describe "error paths" do
    test "missing source records an issue hinting at --list and the source modes" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", [])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "pass a source") and
                 String.contains?(issue, "--list") and
                 String.contains?(issue, "registry")
             end)
    end

    test "unclassifiable source records an issue" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["foo bar"])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "could not classify"))
    end
  end

  describe "--list (no source) — shortcut names" do
    test "prints only the registered shortcut names" do
      output =
        capture_io(fn ->
          test_project()
          |> Igniter.compose_task("hearth.gen", ["--list"])
        end)

      assert output =~ "Hearth shortcuts"
      assert output =~ "* stripe"

      # Stays narrow: no version detail, no URL, no integration name.
      refute output =~ "latest"
      refute output =~ "dahlia"
      refute output =~ "2026-04-22"
      refute output =~ "default integration"
      refute output =~ "https://"
    end

    test "does not run install gating" do
      key = make_ref()

      capture_io(fn ->
        igniter = test_project() |> Igniter.compose_task("hearth.gen", ["--list"])
        Process.put(key, igniter)
      end)

      igniter = Process.get(key)

      assert_unchanged(igniter, [".formatter.exs", "config/config.exs"])
      refute notice_text(igniter) =~ "Hearth v"
    end

    test "sets the quiet_on_no_changes? assign so Igniter does not chatter" do
      key = make_ref()

      capture_io(fn ->
        igniter = test_project() |> Igniter.compose_task("hearth.gen", ["--list"])
        Process.put(key, igniter)
      end)

      igniter = Process.get(key)
      assert igniter.assigns[:quiet_on_no_changes?] == true
    end
  end

  describe "<name> --list — versions for a shortcut" do
    test "prints canonical versions only — aliases are filtered out" do
      output =
        capture_io(fn ->
          test_project()
          |> Igniter.compose_task("hearth.gen", ["stripe", "--list"])
        end)

      assert output =~ "stripe versions:"
      assert output =~ "* latest"
      assert output =~ "* 2026-04-22.dahlia"
      assert output =~ "* 2026-03-25.dahlia"
      assert output =~ "* 2026-02-25.clover"
      assert output =~ "* 2025-08-27.basil"
      assert output =~ "* 2025-03-31.basil"

      # Aliases (dahlia, clover, basil codenames + date-alone forms)
      # resolve at lookup but are invisible to listings — surfacing them
      # confuses the "available versions" surface.
      refute output =~ "* dahlia\n"
      refute output =~ "* clover\n"
      refute output =~ "* basil\n"
      refute output =~ "* 2026-04-22\n"
      refute output =~ "* 2025-03-31\n"

      # The version listing should not also dump the URL or trigger
      # source-recognition output.
      refute output =~ "Source recognized"
      refute output =~ "https://"
    end

    test "codename aliases resolve to the most recent dated release" do
      basil =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@basil"])
        |> notice_text()

      assert basil =~ "registry shorthand `stripe@basil` (alias for `stripe@2025-08-27.basil`)"
      assert basil =~ "v2017"

      clover =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["stripe@clover"])
        |> notice_text()

      assert clover =~ "registry shorthand `stripe@clover` (alias for `stripe@2026-02-25.clover`)"
      assert clover =~ "v2203"
    end

    test "@version on the source is ignored — same answer for any @version" do
      bare =
        capture_io(fn ->
          test_project() |> Igniter.compose_task("hearth.gen", ["stripe", "--list"])
        end)

      pinned =
        capture_io(fn ->
          test_project() |> Igniter.compose_task("hearth.gen", ["stripe@latest", "--list"])
        end)

      anything =
        capture_io(fn ->
          test_project() |> Igniter.compose_task("hearth.gen", ["stripe@anything", "--list"])
        end)

      assert bare == pinned
      assert bare == anything
    end

    test "unknown shortcut + --list records a useful issue" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["unknownvendor", "--list"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "no registry entry for `unknownvendor`") and
                 String.contains?(issue, "stripe")
             end)
    end

    test "file source + --list errors with a clear hint" do
      igniter =
        test_project(files: %{"priv/specs/foo.yaml" => "openapi: 3.0.0\n"})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/foo.yaml", "--list"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "--list with a source only works for registry") and
                 String.contains?(issue, "priv/specs/foo.yaml")
             end)
    end

    test "URL source + --list errors with a clear hint" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["https://example.com/openapi.json", "--list"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "--list with a source only works for registry") and
                 String.contains?(issue, "https://example.com")
             end)
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
