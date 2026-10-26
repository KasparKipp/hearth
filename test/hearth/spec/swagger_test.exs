defmodule Hearth.Spec.SwaggerTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Swagger

  @swagger %{
    "swagger" => "2.0",
    "info" => %{"title" => "Petstore", "version" => "1.0"},
    "host" => "petstore.test",
    "basePath" => "/v2",
    "schemes" => ["https"],
    "consumes" => ["application/json"],
    "produces" => ["application/json"],
    "tags" => [%{"name" => "Pet"}],
    "x-vendor" => "acme",
    "paths" => %{
      "/stores/{storeId}/pets/{petId}" => %{
        "parameters" => [%{"$ref" => "#/parameters/storeId"}],
        "get" => %{
          "operationId" => "getPet",
          "tags" => ["Pet"],
          "parameters" => [
            %{"name" => "petId", "in" => "path", "required" => true, "type" => "string"},
            %{
              "name" => "tags",
              "in" => "query",
              "type" => "array",
              "items" => %{"type" => "string"},
              "collectionFormat" => "multi"
            },
            %{"$ref" => "#/parameters/authKey"}
          ],
          "responses" => %{
            "200" => %{
              "description" => "OK",
              "schema" => %{"$ref" => "#/definitions/pet"},
              "headers" => %{"Location" => %{"type" => "string", "description" => "Where"}}
            },
            "400" => %{"$ref" => "#/responses/400"}
          }
        },
        "put" => %{
          "operationId" => "putPet",
          "parameters" => [
            %{
              "name" => "pet",
              "in" => "body",
              "required" => true,
              "description" => "The pet",
              "schema" => %{"$ref" => "#/definitions/pet"}
            }
          ],
          "responses" => %{"204" => %{"description" => "Done"}}
        }
      },
      "/pets/upload" => %{
        "post" => %{
          "operationId" => "uploadPets",
          "consumes" => ["multipart/form-data"],
          "parameters" => [
            %{"name" => "file", "in" => "formData", "type" => "file", "required" => true},
            %{"name" => "note", "in" => "formData", "type" => "string"}
          ],
          "responses" => %{"200" => %{"description" => "OK"}}
        }
      }
    },
    "parameters" => %{
      "storeId" => %{"name" => "storeId", "in" => "path", "required" => true, "type" => "string"},
      "authKey" => %{
        "name" => "authorization",
        "in" => "header",
        "required" => true,
        "type" => "string"
      }
    },
    "responses" => %{
      "400" => %{"description" => "Bad", "schema" => %{"$ref" => "#/definitions/error"}}
    },
    "definitions" => %{
      "pet" => %{
        "type" => "object",
        "discriminator" => "kind",
        "properties" => %{
          "id" => %{"type" => "string", "x-nullable" => true},
          "tags" => %{"type" => "array", "items" => %{"$ref" => "#/definitions/tag"}}
        }
      },
      "tag" => %{"type" => "object"},
      "error" => %{"type" => "object"}
    },
    "securityDefinitions" => %{
      "key" => %{"type" => "apiKey", "in" => "header", "name" => "x-api-key"},
      "basic" => %{"type" => "basic"},
      "oauth" => %{
        "type" => "oauth2",
        "flow" => "application",
        "tokenUrl" => "https://auth.test/token",
        "scopes" => %{"read" => "Read"}
      }
    },
    "security" => [%{"key" => []}]
  }

  defp convert(spec \\ @swagger), do: Swagger.to_openapi(spec)
  defp op(spec, path, method), do: spec["paths"][path][method]

  test "swagger?/1 tells Swagger 2.0 from OpenAPI 3" do
    assert Swagger.swagger?(@swagger)
    refute Swagger.swagger?(%{"openapi" => "3.0.0"})
  end

  test "an OpenAPI 3 spec passes through untouched" do
    spec = %{"openapi" => "3.1.0", "paths" => %{}}
    assert Swagger.normalize(spec) == spec
    assert Swagger.normalize(@swagger) == convert()
  end

  describe "top level" do
    test "becomes OpenAPI 3.0 and keeps info, tags, security and extensions" do
      spec = convert()

      assert spec["openapi"] == "3.0.3"
      refute Map.has_key?(spec, "swagger")
      assert spec["info"] == @swagger["info"]
      assert spec["tags"] == @swagger["tags"]
      assert spec["security"] == @swagger["security"]
      assert spec["x-vendor"] == "acme"

      for key <-
            ~w(host basePath schemes consumes produces definitions parameters responses securityDefinitions),
          do: refute(Map.has_key?(spec, key), key)
    end

    test "host, basePath and schemes become servers" do
      assert convert()["servers"] == [%{"url" => "https://petstore.test/v2"}]

      spec = convert(Map.put(@swagger, "schemes", ["https", "http"]))

      assert spec["servers"] == [
               %{"url" => "https://petstore.test/v2"},
               %{"url" => "http://petstore.test/v2"}
             ]
    end

    test "no schemes means https; a / basePath adds nothing" do
      spec = @swagger |> Map.delete("schemes") |> Map.put("basePath", "/")
      assert convert(spec)["servers"] == [%{"url" => "https://petstore.test"}]
    end

    test "no host: a relative server with the base path" do
      assert convert(Map.delete(@swagger, "host"))["servers"] == [%{"url" => "/v2"}]

      spec = @swagger |> Map.delete("host") |> Map.delete("basePath")
      refute Map.has_key?(convert(spec), "servers")
    end
  end

  describe "components" do
    test "definitions become schemas, with $refs rewritten" do
      schemas = convert()["components"]["schemas"]

      assert schemas["pet"]["properties"]["tags"]["items"] == %{
               "$ref" => "#/components/schemas/tag"
             }
    end

    test "Swagger-only schema keywords become their OpenAPI 3 form" do
      pet = convert()["components"]["schemas"]["pet"]

      assert pet["discriminator"] == %{"propertyName" => "kind"}
      assert pet["properties"]["id"] == %{"type" => "string", "nullable" => true}
    end

    test "parameters become components, typed through a schema" do
      assert convert()["components"]["parameters"]["authKey"] == %{
               "name" => "authorization",
               "in" => "header",
               "required" => true,
               "schema" => %{"type" => "string"}
             }
    end

    test "responses become components with content" do
      assert convert()["components"]["responses"]["400"] == %{
               "description" => "Bad",
               "content" => %{
                 "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/error"}}
               }
             }
    end

    test "securityDefinitions become securitySchemes" do
      schemes = convert()["components"]["securitySchemes"]

      assert schemes["key"] == %{"type" => "apiKey", "in" => "header", "name" => "x-api-key"}
      assert schemes["basic"] == %{"type" => "http", "scheme" => "basic"}

      assert schemes["oauth"] == %{
               "type" => "oauth2",
               "flows" => %{
                 "clientCredentials" => %{
                   "tokenUrl" => "https://auth.test/token",
                   "scopes" => %{"read" => "Read"}
                 }
               }
             }
    end
  end

  describe "operations" do
    test "keep their id, tags and non-body parameters, refs rewritten" do
      get = op(convert(), "/stores/{storeId}/pets/{petId}", "get")

      assert get["operationId"] == "getPet"
      assert get["tags"] == ["Pet"]

      assert [pet_id, tags, auth] = get["parameters"]

      assert pet_id == %{
               "name" => "petId",
               "in" => "path",
               "required" => true,
               "schema" => %{"type" => "string"}
             }

      assert tags["schema"] == %{"type" => "array", "items" => %{"type" => "string"}}
      assert tags["explode"] == true
      assert auth == %{"$ref" => "#/components/parameters/authKey"}
    end

    test "path-level parameters stay on the path item" do
      item = convert()["paths"]["/stores/{storeId}/pets/{petId}"]
      assert item["parameters"] == [%{"$ref" => "#/components/parameters/storeId"}]
    end

    test "a body parameter becomes the requestBody, per consumed media type" do
      put = op(convert(), "/stores/{storeId}/pets/{petId}", "put")

      assert put["parameters"] == nil

      assert put["requestBody"] == %{
               "required" => true,
               "description" => "The pet",
               "content" => %{
                 "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/pet"}}
               }
             }
    end

    test "formData parameters become a form requestBody" do
      post = op(convert(), "/pets/upload", "post")

      assert post["requestBody"] == %{
               "required" => true,
               "content" => %{
                 "multipart/form-data" => %{
                   "schema" => %{
                     "type" => "object",
                     "properties" => %{
                       "file" => %{"type" => "string", "format" => "binary"},
                       "note" => %{"type" => "string"}
                     },
                     "required" => ["file"]
                   }
                 }
               }
             }
    end

    test "a response schema becomes content per produced media type; headers get a schema" do
      ok = op(convert(), "/stores/{storeId}/pets/{petId}", "get")["responses"]["200"]

      assert ok["content"] == %{
               "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/pet"}}
             }

      assert ok["headers"] == %{
               "Location" => %{"description" => "Where", "schema" => %{"type" => "string"}}
             }

      refute Map.has_key?(ok, "schema")
    end

    test "a response $ref points at components/responses" do
      bad = op(convert(), "/stores/{storeId}/pets/{petId}", "get")["responses"]["400"]
      assert bad == %{"$ref" => "#/components/responses/400"}
    end

    test "a body parameter reached by $ref is inlined as the requestBody" do
      spec =
        @swagger
        |> put_in(["parameters", "petBody"], %{
          "name" => "pet",
          "in" => "body",
          "schema" => %{"$ref" => "#/definitions/pet"}
        })
        |> put_in(
          ["paths", "/stores/{storeId}/pets/{petId}", "put", "parameters"],
          [%{"$ref" => "#/parameters/petBody"}]
        )

      converted = convert(spec)
      put = op(converted, "/stores/{storeId}/pets/{petId}", "put")

      assert put["requestBody"]["content"]["application/json"]["schema"] == %{
               "$ref" => "#/components/schemas/pet"
             }

      refute Map.has_key?(converted["components"]["parameters"], "petBody")
    end
  end
end
