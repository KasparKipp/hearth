defmodule Mix.Tasks.Hearth.Gen.GeneratedTestsTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: the generated auth test and external test scaffold.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

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

      assert source =~ "configure_api_key(@api_key)"
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
end
