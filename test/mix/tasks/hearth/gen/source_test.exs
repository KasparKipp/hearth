defmodule Mix.Tasks.Hearth.Gen.SourceTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: source arguments: recognition, `--list` and error paths.

  import ExUnit.CaptureIO

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @petstore_3_0_json File.read!("test/fixtures/specs/petstore-3.0.json")
  @tictactoe_3_1_yaml File.read!("test/fixtures/specs/tictactoe-3.1.yaml")

  # Stubs the network: every URL serves `body` and is reported back to
  # the test as `{:fetched, url}`.
  defp serve(igniter, body \\ File.read!("test/fixtures/specs/petstore-3.0.yaml")) do
    test = self()

    Igniter.assign(igniter, :hearth_fetch, fn url ->
      send(test, {:fetched, url})
      {:ok, body}
    end)
  end

  defp entry(igniter, key) do
    {:ok, integrations} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    integrations[key]
  end

  describe "remote sources" do
    test "a URL is fetched and generates the integration, recorded as its source" do
      igniter =
        test_project()
        |> serve()
        |> Igniter.compose_task("hearth.gen", [
          "https://specs.example.com/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_received {:fetched, "https://specs.example.com/petstore.yaml"}
      assert_creates(igniter, "lib/test/integrations/petstore/petstore_api.ex")
      assert entry(igniter, :petstore)[:source] == "https://specs.example.com/petstore.yaml"
      assert notice_text(igniter) =~ "Spec loaded from https://specs.example.com/petstore.yaml"
    end

    test "a URL needs --integration" do
      igniter =
        test_project()
        |> serve()
        |> Igniter.compose_task("hearth.gen", ["https://specs.example.com/petstore.yaml"])

      assert issue_text(igniter) =~ "--integration is required for a file or URL source"
    end

    test "a fetch failure halts naming the URL and why" do
      igniter =
        test_project()
        |> Igniter.assign(:hearth_fetch, fn _url -> {:error, {:status, 404}} end)
        |> Igniter.compose_task("hearth.gen", [
          "https://specs.example.com/gone.yaml",
          "--integration",
          "Gone"
        ])

      assert issue_text(igniter) =~ "could not fetch https://specs.example.com/gone.yaml"
      assert issue_text(igniter) =~ "HTTP 404"
    end

    test "test mode never touches the network unless the fetch is stubbed" do
      igniter =
        Igniter.compose_task(test_project(), "hearth.gen", [
          "https://specs.example.com/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert issue_text(igniter) =~ "network_disabled_in_test_mode"
    end

    test "a bare shortcut is pinned to @latest, fetches its URL and names the integration" do
      igniter = test_project() |> serve() |> Igniter.compose_task("hearth.gen", ["STRIPE"])

      assert_received {:fetched, url}
      assert url =~ "refs/heads/master"
      assert_creates(igniter, "lib/test/integrations/stripe.ex")
      assert entry(igniter, :stripe)[:source] == "stripe@latest"
      assert notice_text(igniter) =~ "Resolved `stripe@latest` to:"
    end

    test "an alias says what it resolved to" do
      notices =
        test_project()
        |> serve()
        |> Igniter.compose_task("hearth.gen", ["stripe@dahlia"])
        |> notice_text()

      assert notices =~ "Resolved `stripe@dahlia` (alias for `stripe@2026-04-22.dahlia`) to:"
      assert_received {:fetched, url}
      assert url =~ "v2266"
    end

    test "codename aliases resolve to the most recent dated release" do
      test_project() |> serve() |> Igniter.compose_task("hearth.gen", ["stripe@basil"])
      assert_received {:fetched, basil}
      assert basil =~ "v2017"

      test_project() |> serve() |> Igniter.compose_task("hearth.gen", ["stripe@clover"])
      assert_received {:fetched, clover}
      assert clover =~ "v2203"
    end

    test "a .hearth.exs registry shortcut resolves to its URL or file" do
      exs = """
      [
        registry: %{
          "acme" => %{
            "1" => "https://acme.test/v1.yaml",
            "2" => "priv/specs/acme-2.yaml",
            "latest" => {:alias, "2"}
          }
        }
      ]
      """

      igniter =
        test_project(files: %{".hearth.exs" => exs})
        |> serve()
        |> Igniter.compose_task("hearth.gen", ["acme@1"])

      assert_received {:fetched, "https://acme.test/v1.yaml"}
      assert_creates(igniter, "lib/test/integrations/acme.ex")
      assert entry(igniter, :acme)[:source] == "acme@1"
      assert notice_text(igniter) =~ "Resolved `acme@1` from .hearth.exs to:"

      from_file =
        test_project(
          files: %{".hearth.exs" => exs, "priv/specs/acme-2.yaml" => @petstore_3_0_yaml}
        )
        |> Igniter.compose_task("hearth.gen", ["acme"])

      assert entry(from_file, :acme)[:source] == "acme@latest"
      assert notice_text(from_file) =~ "priv/specs/acme-2.yaml"
    end

    test "a URL + --list prints its tag discovery" do
      output =
        capture_io(fn ->
          test_project()
          |> serve()
          |> Igniter.compose_task("hearth.gen", [
            "https://specs.example.com/petstore.yaml",
            "--list"
          ])
        end)

      assert output =~ ":list_pets"
    end

    test "--list marks shortcuts from .hearth.exs" do
      exs = ~s|[registry: %{"acme" => %{"1" => "https://acme.test/v1.yaml"}}]|

      output =
        capture_io(fn ->
          test_project(files: %{".hearth.exs" => exs})
          |> Igniter.compose_task("hearth.gen", ["--list"])
        end)

      assert output =~ "acme (.hearth.exs)"
      assert output =~ "stripe"
    end
  end

  describe "source recognition" do
    test "YAML file source decodes, summarizes, and generates the behaviour" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      notice = notice_text(igniter)
      assert notice =~ "Spec loaded from priv/specs/petstore.yaml"
      assert notice =~ "Swagger Petstore"
      assert notice =~ "OpenAPI 3.0.0"
      assert notice =~ ~r/\d+ operations/
      assert notice =~ "Test.Integrations.Petstore.PetstoreApi"
    end

    test "JSON file source decodes and generates the behaviour" do
      igniter =
        test_project(files: %{"priv/specs/petstore.json" => @petstore_3_0_json})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.json",
          "--integration",
          "Petstore"
        ])

      notice = notice_text(igniter)
      assert notice =~ "Spec loaded"
      assert notice =~ "Swagger Petstore"
    end

    test "OAS 3.1 file source decodes correctly" do
      igniter =
        test_project(files: %{"priv/specs/tictactoe.yaml" => @tictactoe_3_1_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/tictactoe.yaml",
          "--integration",
          "Tictactoe"
        ])

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

    test "a file source + --list prints the spec's tag discovery instead of erroring" do
      output =
        capture_io(fn ->
          test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
          |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml", "--list"])
        end)

      assert output =~ "operations across"
      assert output =~ ~s("pets":)
      assert output =~ ":list_pets"
      assert output =~ "Generate a subset"
    end
  end
end
