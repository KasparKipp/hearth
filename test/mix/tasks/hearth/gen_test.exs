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

  # The content of a file the task created/updated, read back out of the
  # igniter's in-memory Rewrite (compose_task preserves rewrite changes).
  defp created_file(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  # A JSON spec with `count` GET operations, all under one "Things" tag,
  # for exercising the operation-count gate.
  defp big_spec_json(count) do
    paths =
      Map.new(1..count, fn i ->
        {"/thing#{i}", %{"get" => %{"operationId" => "getThing#{i}", "tags" => ["Things"]}}}
      end)

    JSON.encode!(%{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Big API", "version" => "1.0.0"},
      "paths" => paths
    })
  end

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

  describe "operation selection and the --n-operations gate" do
    test "a spec under the gate proceeds and reports the selection" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert notice_text(igniter) =~ "Selected 3 of 3 operations across 1 tag."
    end

    test "a spec over the gate with no --tag halts with the tag-discovery listing" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "30 operations") and
                 String.contains?(issue, "limit (25)") and
                 String.contains?(issue, ~s("Things":)) and
                 String.contains?(issue, ":get_thing1") and
                 String.contains?(issue, "--n-operations 30")
             end)

      refute notice_text(igniter) =~ "Selected"
    end

    test "--tag skips the gate even when the spec is over the limit" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--tag",
          "Things"
        ])

      assert notice_text(igniter) =~ "Selected 30 of 30 operations across 1 tag."
    end

    test "--tag narrows the selection to specific operationIds" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--tag",
          "Things:get_thing1,get_thing2"
        ])

      assert notice_text(igniter) =~ "Selected 2 of 30 operations"
    end

    test "--n-operations raises the gate so a big spec proceeds" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--n-operations",
          "30"
        ])

      assert notice_text(igniter) =~ "Selected 30 of 30 operations"
    end

    test "a malformed --tag value halts with the parse error" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json", "--tag", "Things:a:b"])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "comma-separated"))
      refute notice_text(igniter) =~ "Selected"
    end

    test "the gate discovery echoes the real source and integration in the subset command" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json", "--integration", "Big"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(
                 issue,
                 "mix hearth.gen priv/specs/big.json --integration Big"
               ) and String.contains?(issue, ~s(--tag "Things:get_thing1,))
             end)
    end

    test "the subset command spells out every tag with its operationIds, one --tag per line" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "Multi", "version" => "1.0"},
          "paths" => %{
            "/a" => %{"get" => %{"operationId" => "getA", "tags" => ["Search"]}},
            "/b" => %{"get" => %{"operationId" => "getB", "tags" => ["Validation"]}}
          }
        })

      output =
        capture_io(fn ->
          test_project(files: %{"priv/specs/multi.json" => spec})
          |> Igniter.compose_task("hearth.gen", [
            "priv/specs/multi.json",
            "--integration",
            "Multi",
            "--list"
          ])
        end)

      assert output =~
               ~s(mix hearth.gen priv/specs/multi.json --integration Multi \\\n) <>
                 ~s(    --tag "Search:get_a" \\\n    --tag "Validation:get_b")
    end
  end

  describe "Layer 1 generation" do
    @petstore_layer1 "lib/test/integrations/petstore.ex"

    test "writes the raw Req client module alongside the behaviour" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @petstore_layer1)
      source = created_file(igniter, @petstore_layer1)
      assert source =~ "defmodule Test.Integrations.Petstore do"
      assert source =~ "def new("
    end

    test "the base URL comes from the spec's servers" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert created_file(igniter, @petstore_layer1) =~
               ~s(@base_url "http://petstore.swagger.io/v1")
    end

    test "an API-key security scheme renders a credential reader" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "Keyed", "version" => "1.0"},
          "servers" => [%{"url" => "https://keyed.example.com"}],
          "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}},
          "components" => %{
            "securitySchemes" => %{
              "ApiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
            }
          }
        })

      igniter =
        test_project(files: %{"priv/specs/keyed.json" => spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/keyed.json",
          "--integration",
          "Keyed"
        ])

      source = created_file(igniter, "lib/test/integrations/keyed.ex")
      assert source =~ ~s|headers: [{"X-API-Key", credential(opts)}]|
      assert source =~ "defp credential(opts)"
    end

    test "the notice lists all four generated files" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      notice = notice_text(igniter)
      assert notice =~ "lib/test/integrations/petstore.ex"
      assert notice =~ "lib/test/integrations/petstore/petstore_api.ex"
      assert notice =~ "lib/test/integrations/petstore/petstore_api/req.ex"
      assert notice =~ "test/test/integrations/petstore_test.exs"
      assert notice =~ "raw Req client"
      assert notice =~ "Req implementation"
      assert notice =~ "Layer 1 auth test"
    end

    test "the notice reports the wired files" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      notice = notice_text(igniter)
      assert notice =~ "wiring test/support/mocks.ex"
      assert notice =~ "wiring config/config.exs"
      assert notice =~ "wiring config/test.exs"
    end
  end

  describe "Layer 1 test generation" do
    @petstore_layer1_test "test/test/integrations/petstore_test.exs"

    test "writes a Req.Test auth test alongside the client" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @petstore_layer1_test)
      source = created_file(igniter, @petstore_layer1_test)
      assert source =~ "if Code.ensure_loaded?(Plug.Conn) do"
      assert source =~ "defmodule Test.Integrations.PetstoreTest do"
      assert source =~ "use ExUnit.Case, async: false"
      assert source =~ "@client Test.Integrations.Petstore"
      assert source =~ ~s|@client.request!("/ping", plug: plug)|
    end

    test "an API-key spec generates a header assertion and seeds the credential" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "Keyed", "version" => "1.0"},
          "servers" => [%{"url" => "https://keyed.example.com"}],
          "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}},
          "components" => %{
            "securitySchemes" => %{
              "ApiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
            }
          }
        })

      igniter =
        test_project(files: %{"priv/specs/keyed.json" => spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/keyed.json",
          "--integration",
          "Keyed"
        ])

      source = created_file(igniter, "test/test/integrations/keyed_test.exs")

      assert source =~
               "Application.put_env(:test, @client, Keyword.put(previous, :api_key, @api_key))"

      assert source =~ ~s|Plug.Conn.get_req_header(conn, "x-api-key") == [@api_key]|
    end

    test "no plug dependency is added — the test self-guards instead" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      refute created_file(igniter, "mix.exs") =~ ":plug"

      assert created_file(igniter, @petstore_layer1_test) =~
               "if Code.ensure_loaded?(Plug.Conn) do"
    end
  end

  describe "host wiring — Mox mock" do
    @keyed_spec JSON.encode!(%{
                  "openapi" => "3.0.0",
                  "info" => %{"title" => "Keyed", "version" => "1.0"},
                  "servers" => [%{"url" => "https://keyed.example.com"}],
                  "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}},
                  "components" => %{
                    "securitySchemes" => %{
                      "ApiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
                    }
                  }
                })

    defp gen(igniter, source, integration) do
      Igniter.compose_task(igniter, "hearth.gen", [source, "--integration", integration])
    end

    test "creates test/support/mocks.ex with a Mox.defmock per integration" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      source = created_file(igniter, "test/support/mocks.ex")
      assert source =~ "Mox.defmock(Test.Integrations.Petstore.PetstoreApi.Mock,"
      assert source =~ "for: Test.Integrations.Petstore.PetstoreApi"
    end

    test "adds {:mox, …, only: :test} to the consumer's deps" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      mix_exs = created_file(igniter, "mix.exs")
      assert mix_exs =~ ":mox"
      assert mix_exs =~ "only: [:test]" or mix_exs =~ "only: :test"
    end

    test "queues `mix deps.get` when it added deps to mix.exs" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      assert {"deps.get", []} in igniter.tasks
    end

    test "a second integration appends without clobbering the first" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "priv/specs/keyed.json" => @keyed_spec
          }
        )
        |> gen("priv/specs/petstore.yaml", "Petstore")
        |> gen("priv/specs/keyed.json", "Keyed")

      source = created_file(igniter, "test/support/mocks.ex")
      assert source =~ "Test.Integrations.Petstore.PetstoreApi.Mock"
      assert source =~ "Test.Integrations.Keyed.KeyedApi.Mock"
    end
  end

  describe "host wiring — config" do
    test "config/test.exs points the dispatcher at the Mox mock" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, "config/test.exs")
      assert source =~ "Test.Integrations.Petstore.PetstoreApi"
      assert source =~ "impl: Test.Integrations.Petstore.PetstoreApi.Mock"
    end

    test "the Layer 2 module is appended to :hearth_domains" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, "config/config.exs")
      assert source =~ "hearth_domains"
      assert source =~ "Test.Integrations.Petstore.PetstoreApi"
    end

    test "an API-key spec wires a runtime.exs credential for prod and dev" do
      igniter =
        test_project(files: %{"priv/specs/keyed.json" => @keyed_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/keyed.json",
          "--integration",
          "Keyed"
        ])

      source = created_file(igniter, "config/runtime.exs")
      assert source =~ ~s|System.get_env("KEYED_API_KEY")|
      assert source =~ "config_env() == :prod"
      assert source =~ "config_env() == :dev"
      assert source =~ "DEV_NO_KEYED_API_KEY"
    end

    test "a :none-auth spec leaves config/runtime.exs untouched" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      refute Igniter.exists?(igniter, "config/runtime.exs")
    end

    test "a :hearth_domains opt-out (false) is left untouched" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "config/config.exs" => "import Config\n\nconfig :test, :hearth_domains, false\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, "config/config.exs")
      assert source =~ "hearth_domains, false"
      refute source =~ "PetstoreApi"
    end
  end

  describe "external integration test generation" do
    @external_path "test/test/integrations/petstore_external_test.exs"

    test "writes an :external-tagged test, one test per operation" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @external_path)
      source = created_file(igniter, @external_path)
      assert source =~ "defmodule Test.Integrations.PetstoreExternalTest do"
      assert source =~ "@moduletag :external"
      assert source =~ ~s(test "list_pets reaches the live API" do)
      # calls Layer 3 (.Req) directly, bypassing the mock-routed dispatcher
      assert source =~ "PetstoreApi.Req.list_pets("
    end

    test "patches test_helper.exs to exclude :external by default" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert created_file(igniter, "test/test_helper.exs") =~
               "ExUnit.configure(exclude: [:external])"
    end

    test "the notice lists the external test" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      notice = notice_text(igniter)
      assert notice =~ @external_path
      assert notice =~ "external integration test"
    end
  end

  describe "pruned spec artifact" do
    test "writes a pruned spec to priv/hearth/<name>.yaml" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, "priv/hearth/petstore.yaml")
      yaml = created_file(igniter, "priv/hearth/petstore.yaml")

      assert {:ok, parsed} = YamlElixir.read_from_string(yaml)
      assert parsed["openapi"]
      assert Map.has_key?(parsed["paths"], "/pets")
    end

    test "--tag prunes the spec's paths to the selected operations" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--tag",
          "pets:list_pets"
        ])

      parsed =
        igniter
        |> created_file("priv/hearth/petstore.yaml")
        |> YamlElixir.read_from_string!()

      # only list_pets survives — its sibling create_pets (POST /pets)
      # and show_pet_by_id (/pets/{petId}) are pruned out
      assert Map.keys(parsed["paths"]) == ["/pets"]
      refute Map.has_key?(parsed["paths"]["/pets"], "post")
    end

    test "the notice lists the pruned spec" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert notice_text(igniter) =~ "priv/hearth/petstore.yaml"
    end
  end

  describe "multi-server base URLs" do
    defp server_spec(urls) do
      JSON.encode!(%{
        "openapi" => "3.0.0",
        "info" => %{"title" => "Multi", "version" => "1.0"},
        "servers" => Enum.map(urls, &%{"url" => &1}),
        "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}}
      })
    end

    defp gen_servers(urls) do
      test_project(files: %{"priv/specs/m.json" => server_spec(urls)})
      |> Igniter.compose_task("hearth.gen", ["priv/specs/m.json", "--integration", "Acme"])
    end

    test "the prod server is Layer 1's @base_url; the non-prod one goes to config/test.exs" do
      igniter = gen_servers(["https://staging.acme.com", "https://api.acme.com"])

      assert created_file(igniter, "lib/test/integrations/acme.ex") =~
               ~s(@base_url "https://api.acme.com")

      assert created_file(igniter, "config/test.exs") =~
               ~s(base_url: "https://staging.acme.com")
    end

    test "extra prod servers become commented overrides in config/config.exs" do
      igniter =
        gen_servers(["https://api.acme.com", "https://eu.acme.com", "https://staging.acme.com"])

      config = created_file(igniter, "config/config.exs")
      assert config =~ "# Hearth: alternate base URLs"
      assert config =~ ~s(base_url: "https://eu.acme.com")
    end

    test "extra non-prod servers become commented options in config/test.exs" do
      igniter =
        gen_servers([
          "https://api.acme.com",
          "https://staging.acme.com",
          "https://dev.acme.com"
        ])

      test_config = created_file(igniter, "config/test.exs")
      assert test_config =~ "# Hearth: alternate base URLs"
      assert test_config =~ ~s(base_url: "https://dev.acme.com")
    end

    test "a spec with no servers emits a base-URL warning" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "NoServers", "version" => "1.0"},
          "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}}
        })

      igniter =
        test_project(files: %{"priv/specs/n.json" => spec})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/n.json", "--integration", "Acme"])

      assert Enum.any?(igniter.warnings, &String.contains?(&1, "declared no `servers`"))
    end
  end

  describe "shared base path" do
    @versioned_spec JSON.encode!(%{
                      "openapi" => "3.0.0",
                      "info" => %{"title" => "Versioned", "version" => "1.0"},
                      "servers" => [%{"url" => "https://api.example.com"}],
                      "paths" => %{
                        "/api/v1/customers" => %{
                          "get" => %{"operationId" => "listCustomers", "tags" => ["Customers"]}
                        },
                        "/api/v1/customers/{id}" => %{
                          "get" => %{
                            "operationId" => "getCustomer",
                            "tags" => ["Customers"],
                            "parameters" => [%{"name" => "id", "in" => "path"}]
                          }
                        }
                      }
                    })

    test "a path prefix shared by every operation is folded into the base URL" do
      igniter =
        test_project(files: %{"priv/specs/versioned.json" => @versioned_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/versioned.json",
          "--integration",
          "Versioned"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/versioned.ex")
      assert layer1 =~ ~s(@base_url "https://api.example.com/api/v1")

      layer3 = created_file(igniter, "lib/test/integrations/versioned/versioned_api/req.ex")
      assert layer3 =~ "Versioned.request(\"/customers\", opts)"
      assert layer3 =~ "Versioned.request(\"/customers/\#{id}\", opts)"
    end

    @no_servers_spec JSON.encode!(%{
                       "openapi" => "3.0.0",
                       "info" => %{"title" => "Serverless", "version" => "1.0"},
                       "paths" => %{
                         "/v3/notices" => %{
                           "get" => %{"operationId" => "listNotices", "tags" => ["Notices"]}
                         },
                         "/v3/notices/search" => %{
                           "get" => %{"operationId" => "searchNotices", "tags" => ["Notices"]}
                         }
                       }
                     })

    test "the prefix folds into the base-URL placeholder when the spec has no servers" do
      igniter =
        test_project(files: %{"priv/specs/srv.json" => @no_servers_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/srv.json",
          "--integration",
          "Srv"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/srv.ex")
      assert layer1 =~ "# TODO: the spec declared no `servers`"
      assert layer1 =~ ~s(@base_url "https://api.example.com/v3")

      layer3 = created_file(igniter, "lib/test/integrations/srv/srv_api/req.ex")
      assert layer3 =~ "Srv.request(\"/notices\", opts)"
      assert layer3 =~ "Srv.request(\"/notices/search\", opts)"
    end

    @templated_prefix_spec JSON.encode!(%{
                             "openapi" => "3.0.0",
                             "info" => %{"title" => "Accounts", "version" => "1.0"},
                             "servers" => [%{"url" => "https://api.example.com"}],
                             "paths" => %{
                               "/v1/accounts/{account_id}/charges" => %{
                                 "get" => %{
                                   "operationId" => "listCharges",
                                   "parameters" => [%{"name" => "account_id", "in" => "path"}]
                                 }
                               },
                               "/v1/accounts/{account_id}/payouts" => %{
                                 "get" => %{
                                   "operationId" => "listPayouts",
                                   "parameters" => [%{"name" => "account_id", "in" => "path"}]
                                 }
                               }
                             }
                           })

    test "a shared path param stays in the operation path, not the base URL" do
      igniter =
        test_project(files: %{"priv/specs/accounts.json" => @templated_prefix_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/accounts.json",
          "--integration",
          "Accounts"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/accounts.ex")
      assert layer1 =~ ~s(@base_url "https://api.example.com/v1/accounts")

      layer3 = created_file(igniter, "lib/test/integrations/accounts/accounts_api/req.ex")
      assert layer3 =~ "def list_charges(account_id, opts \\\\ [])"
      assert layer3 =~ "Accounts.request(\"/\#{account_id}/charges\", opts)"
    end
  end

  describe "generated identifiers" do
    # Every name here is a trap: reserved words, a leading digit, `opts`
    # (the trailing keyword arg), `impl` (Layer 2's private dispatcher),
    # `module_info` (compiler-defined), and two path params that
    # collide once snake_cased.
    @nasty_spec JSON.encode!(%{
                  "openapi" => "3.0.0",
                  "info" => %{"title" => "Nasty", "version" => "1.0"},
                  "servers" => [%{"url" => "https://api.example.com"}],
                  "paths" => %{
                    "/items/{opts}/{1id}/{end}" => %{"get" => %{"operationId" => "end"}},
                    "/impl" => %{"post" => %{"operationId" => "impl"}},
                    "/users/{petId}/{pet_id}" => %{"get" => %{"operationId" => "moduleInfo"}},
                    "/verify" => %{"post" => %{"operationId" => "2fa-verify"}}
                  }
                })

    test "a spec full of unsafe names generates layers that compile cleanly" do
      igniter =
        test_project(files: %{"priv/specs/nasty.json" => @nasty_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/nasty.json",
          "--integration",
          "Nasty"
        ])

      assert igniter.issues == []

      sources =
        Enum.map(
          [
            "lib/test/integrations/nasty.ex",
            "lib/test/integrations/nasty/nasty_api.ex",
            "lib/test/integrations/nasty/nasty_api/req.ex"
          ],
          &created_file(igniter, &1)
        )

      {_modules, diagnostics} =
        Code.with_diagnostics(fn ->
          Enum.flat_map(sources, &Code.compile_string/1)
        end)

      assert diagnostics == []

      layer3 = Enum.at(sources, 2)
      assert layer3 =~ "def end_(opts_, param_1id, end_, opts \\\\ [])"
      assert layer3 =~ ~S|Nasty.request("/items/#{opts_}/#{param_1id}/#{end_}", opts)|
      assert layer3 =~ "def module_info_(pet_id, pet_id_2, opts \\\\ [])"
      assert layer3 =~ ~S|Nasty.request("/users/#{pet_id}/#{pet_id_2}", opts)|
      assert layer3 =~ "def impl_(opts \\\\ [])"
      assert layer3 =~ "def op_2fa_verify(opts \\\\ [])"
    end
  end

  describe "Layer 3 generation" do
    @petstore_layer3 "lib/test/integrations/petstore/petstore_api/req.ex"

    test "writes the Req implementation module" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @petstore_layer3)
      source = created_file(igniter, @petstore_layer3)
      assert source =~ "defmodule Test.Integrations.Petstore.PetstoreApi.Req do"
      assert source =~ "@behaviour Test.Integrations.Petstore.PetstoreApi"
      assert source =~ "@impl true"
      assert source =~ "Petstore.request(\"/pets\", opts)"

      assert source =~
               "Petstore.request(\"/pets/\#{pet_id}\", opts)"
    end

    test "the gen run adds {:req, …} to the consumer's deps" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert created_file(igniter, "mix.exs") =~ ":req"
    end

    test "a --tag filter matching no operations halts instead of generating empty modules" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--tag",
          "NoSuchTag"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "no operations matched"))
      refute notice_text(igniter) =~ "generating"
    end

    test "the no-match hint names the actual spec path, not a `<source>` placeholder" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--tag",
          "NoSuchTag"
        ])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "priv/specs/petstore.yaml --list") and
                 not String.contains?(issue, "<source>")
             end)
    end
  end

  describe "Layer 2 generation" do
    @petstore_layer2 "lib/test/integrations/petstore/petstore_api.ex"

    test "writes the behaviour module to the conventional path" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @petstore_layer2)
    end

    test "the behaviour has a callback per selected operation" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, @petstore_layer2)
      assert source =~ "defmodule Test.Integrations.Petstore.PetstoreApi do"
      assert source =~ "@callback list_pets(opts :: keyword())"
      assert source =~ "@callback create_pets(opts :: keyword())"
      assert source =~ "@callback show_pet_by_id(pet_id :: String.t(), opts :: keyword())"
    end

    test "the behaviour moduledoc records the source path and spec info" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, @petstore_layer2)
      assert source =~ "## Source"
      assert source =~ ~s(* **Source:** `priv/specs/petstore.yaml`)
      assert source =~ "* **Title:** Swagger Petstore"
      assert source =~ "* **Version:** 1.0.0"
    end

    test "--tag narrows which callbacks are generated" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--tag",
          "pets:list_pets"
        ])

      source = created_file(igniter, @petstore_layer2)
      assert source =~ "@callback list_pets("
      refute source =~ "@callback create_pets("
      refute source =~ "@callback show_pet_by_id("
    end

    test "--domain replaces the default Integrations segment" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--domain",
          "Billing"
        ])

      path = "lib/test/billing/petstore/petstore_api.ex"
      assert_creates(igniter, path)

      assert created_file(igniter, path) =~
               "defmodule Test.Billing.Petstore.PetstoreApi"
    end

    test "--no-domain drops the namespace segment entirely" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--no-domain"
        ])

      path = "lib/test/petstore/petstore_api.ex"
      assert_creates(igniter, path)
      assert created_file(igniter, path) =~ "defmodule Test.Petstore.PetstoreApi"
    end

    test "a file source without --integration halts with a helpful issue" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "--integration is required") and
                 String.contains?(issue, "priv/specs/petstore.yaml")
             end)
    end
  end

  describe "create-only — gen never overwrites" do
    test "halts when the integration's Layer 1 module already exists" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "lib/test/integrations/petstore.ex" =>
              "defmodule Test.Integrations.Petstore do\nend\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "Test.Integrations.Petstore already exists") and
                 String.contains?(issue, "only creates")
             end)

      refute notice_text(igniter) =~ "Spec loaded"
    end

    test "halts on a partial deletion — only Layer 2 left, Layer 1 gone" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "lib/test/integrations/petstore/petstore_api.ex" =>
              "defmodule Test.Integrations.Petstore.PetstoreApi do\nend\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "Test.Integrations.Petstore already exists") and
                 String.contains?(issue, "petstore/petstore_api.ex")
             end)

      refute notice_text(igniter) =~ "Spec loaded"
    end

    test "a fresh project still generates" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert igniter.issues == []
      assert_creates(igniter, "lib/test/integrations/petstore.ex")
    end

    test "re-running the same gen halts on the second run" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "already exists"))
    end
  end

  describe "--integration / --domain validation" do
    defp gen_with(args) do
      test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
      |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml" | args])
    end

    for bad <- ["Foo Bar", "123", "", "Foo.Bar"] do
      test "rejects --integration #{inspect(bad)} with a clear issue, no crash" do
        igniter = gen_with(["--integration", unquote(bad)])

        assert Enum.any?(igniter.issues, fn issue ->
                 String.contains?(issue, "--integration") and
                   String.contains?(issue, "not a valid module name")
               end)

        refute notice_text(igniter) =~ "Spec loaded"
      end
    end

    test "rejects a malformed --domain" do
      igniter = gen_with(["--integration", "Petstore", "--domain", "bad value"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "--domain") and
                 String.contains?(issue, "not a valid module name")
             end)
    end

    test "accepts a snake_case --integration, camelizing it" do
      igniter = gen_with(["--integration", "send_grid"])

      assert igniter.issues == []
      assert_creates(igniter, "lib/test/integrations/send_grid.ex")

      assert created_file(igniter, "lib/test/integrations/send_grid.ex") =~
               "defmodule Test.Integrations.SendGrid do"
    end
  end

  describe "--n-operations validation" do
    for bad <- ["-5", "0"] do
      test "rejects --n-operations #{bad}" do
        igniter =
          test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
          |> Igniter.compose_task("hearth.gen", [
            "priv/specs/petstore.yaml",
            "--integration",
            "Petstore",
            "--n-operations",
            unquote(bad)
          ])

        assert Enum.any?(
                 igniter.issues,
                 &String.contains?(&1, "--n-operations must be a positive integer")
               )

        refute notice_text(igniter) =~ "Spec loaded"
      end
    end

    test "accepts a positive --n-operations" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--n-operations",
          "3"
        ])

      assert igniter.issues == []
      assert notice_text(igniter) =~ "Selected 3 of 3 operations"
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

    test "URL source + --list errors — the fetcher is not yet wired" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.gen", ["https://example.com/openapi.json", "--list"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "URL source needs the fetcher") and
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
