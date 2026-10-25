defmodule Mix.Tasks.Hearth.Gen.LayersTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: the rendered layers and the identifiers in them.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

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
      assert source =~ ~s|Req.Request.put_header(request, "x-api-key", credential(request))|
      assert source =~ "defp credential(request)"
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
      refute notice =~ "hearth_domains"
      assert notice =~ "wiring config/test.exs"
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
end
