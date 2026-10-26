defmodule Mix.Tasks.Hearth.SwaggerTest do
  use Hearth.TaskCase, async: true

  # Swagger 2.0 sources, end to end, on the Swagger petstore
  # (petstore.swagger.io/v2/swagger.json): host + basePath + two
  # schemes, body and formData parameters (a file upload among them),
  # a `collectionFormat: multi` query, and API-key / OAuth2 security
  # definitions.

  @source File.read!("test/fixtures/specs/petstore-swagger-2.0.json")

  @layer1 "lib/test/integrations/petstore.ex"
  @layer3 "lib/test/integrations/petstore/petstore_api/req.ex"

  defp gen(source \\ @source) do
    test_project(files: %{"priv/specs/petstore.json" => source})
    |> Igniter.compose_task("hearth.gen", [
      "priv/specs/petstore.json",
      "--integration",
      "Petstore"
    ])
  end

  defp pruned(igniter),
    do: igniter |> created_file("priv/hearth/petstore.yaml") |> YamlElixir.read_from_string!()

  # The source with upstream changes: a new Pet property and a new
  # status enum value.
  defp upstream_change do
    @source
    |> JSON.decode!()
    |> put_in(["definitions", "Pet", "properties", "nickname"], %{"type" => "string"})
    |> update_in(["definitions", "Pet", "properties", "status", "enum"], &(&1 ++ ["reserved"]))
    |> JSON.encode!()
  end

  describe "gen" do
    test "converts the source, and says so" do
      igniter = gen()

      assert igniter.issues == []

      assert notice_text(igniter) =~
               "The source is Swagger 2.0; Hearth converted it to OpenAPI 3.0."

      pruned = pruned(igniter)
      assert pruned["openapi"] == "3.0.3"
      refute Map.has_key?(pruned, "swagger")
      refute Map.has_key?(pruned, "definitions")
      assert Map.has_key?(pruned["components"]["schemas"], "Pet")
    end

    test "host, basePath and schemes become the base URL and an alternate" do
      igniter = gen()

      assert created_file(igniter, @layer1) =~ ~s(@base_url "https://petstore.swagger.io/v2")
      assert created_file(igniter, "config/config.exs") =~ "http://petstore.swagger.io/v2"
    end

    test "generates a function per operation, path params first" do
      layer3 = created_file(gen(), @layer3)

      assert layer3 =~ "def get_pet_by_id(pet_id, opts \\\\ [])"
      assert layer3 =~ "def upload_file(pet_id, opts \\\\ [])"

      assert layer3 =~
               ~s|Petstore.request("/pet/\#{pet_id}/uploadImage", [method: :post] ++ opts)|

      assert layer3 =~ "def find_pets_by_status(opts \\\\ [])"
    end

    test "body and formData parameters become request bodies in the pruned spec" do
      paths = pruned(gen())["paths"]

      assert Map.keys(paths["/pet"]["post"]["requestBody"]["content"]) ==
               ["application/json", "application/xml"]

      upload = paths["/pet/{petId}/uploadImage"]["post"]["requestBody"]["content"]
      file = upload["multipart/form-data"]["schema"]["properties"]["file"]

      assert file == %{
               "type" => "string",
               "format" => "binary",
               "description" => "file to upload"
             }
    end

    test "regen and diff are clean right after gen" do
      igniter = gen() |> apply_igniter!()

      igniter |> Igniter.compose_task("hearth.regen", ["petstore"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["petstore"]) |> notice_text() =~
               "no drift"
    end
  end

  describe "an upstream change" do
    test "diff reports the schema drift; --sync applies it, then diff is clean" do
      igniter =
        gen()
        |> apply_igniter!()
        |> Igniter.create_new_file("priv/specs/petstore-next.json", upstream_change())
        |> apply_igniter!()

      report =
        igniter
        |> Igniter.compose_task("hearth.diff", [
          "petstore",
          "--source",
          "priv/specs/petstore-next.json"
        ])
        |> issue_text()

      assert report =~ "Pet: property nickname added"
      assert report =~ "enum gains reserved"

      synced =
        igniter
        |> Hearth.Config.Project.put_fields(:petstore, source: "priv/specs/petstore-next.json")
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.regen", ["petstore", "--sync"])
        |> apply_igniter!()

      assert synced |> Igniter.compose_task("hearth.diff", ["petstore"]) |> notice_text() =~
               "no drift"
    end
  end
end
