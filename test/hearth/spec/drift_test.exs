defmodule Hearth.Spec.DriftTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Drift

  @pet %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

  defp spec(paths, schemas \\ %{"Pet" => @pet}) do
    %{
      "openapi" => "3.0.0",
      "paths" => paths,
      "components" => %{
        "schemas" => schemas,
        "parameters" => %{
          "Limit" => %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}}
        }
      }
    }
  end

  @list %{
    "operationId" => "listPets",
    "parameters" => [%{"$ref" => "#/components/parameters/Limit"}]
  }
  @show %{
    "operationId" => "showPet",
    "parameters" => [%{"name" => "id", "in" => "path", "required" => true}],
    "responses" => %{
      "200" => %{
        "content" => %{
          "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Pet"}}
        }
      }
    }
  }

  defp base, do: spec(%{"/pets" => %{"get" => @list}, "/pets/{id}" => %{"get" => @show}})

  defp summary(changes) do
    Enum.map(changes, &{&1.area, &1.kind, &1.subject, &1.detail, &1.breaking?})
  end

  describe "compare/2" do
    test "no drift between identical specs" do
      assert Drift.compare(base(), base()) == []
    end

    test "an added operation is additive, a removed one breaking" do
      added =
        spec(%{
          "/pets" => %{"get" => @list, "post" => %{"operationId" => "createPet"}},
          "/pets/{id}" => %{"get" => @show}
        })

      assert summary(Drift.compare(base(), added)) == [
               {:operation, :added, "post /pets (createPet)", nil, false}
             ]

      assert summary(Drift.compare(added, base())) == [
               {:operation, :removed, "post /pets (createPet)", nil, true}
             ]
    end

    test "an operationId-only rename is drift, but not breaking — the hint names the call sites" do
      renamed = put_in(base(), ["paths", "/pets", "get", "operationId"], "listAllPets")

      assert summary(Drift.compare(base(), renamed)) == [
               {:operation, :changed, "get /pets (listPets)",
                "renamed to listAllPets — call sites: list_pets → list_all_pets", false}
             ]
    end

    test "a rename that keeps the function name says so" do
      renamed = put_in(base(), ["paths", "/pets", "get", "operationId"], "ListPets")

      assert summary(Drift.compare(base(), renamed)) == [
               {:operation, :changed, "get /pets (listPets)",
                "operationId listPets → ListPets (function name unchanged)", false}
             ]
    end

    test "a rename alongside other changes reports each with its own verdict" do
      renamed =
        base()
        |> put_in(["paths", "/pets", "get", "operationId"], "listAllPets")
        |> put_in(["paths", "/pets", "get", "parameters"], [])

      assert [
               %{
                 detail: "renamed to listAllPets — call sites: list_pets → list_all_pets",
                 breaking?: false
               },
               %{detail: "query parameter limit removed", breaking?: true}
             ] = Drift.compare(base(), renamed)
    end

    test "an operation moved to another path keeps its function" do
      moved = spec(%{"/v2/pets" => %{"get" => @list}, "/pets/{id}" => %{"get" => @show}})

      assert summary(Drift.compare(base(), moved)) == [
               {:operation, :changed, "get /pets (listPets)", "moved to get /v2/pets", false}
             ]
    end

    test "a move that changes the path parameters is breaking" do
      moved = spec(%{"/pets" => %{"get" => @list}, "/pets/{petId}/{tag}" => %{"get" => @show}})

      assert [%{kind: :changed, breaking?: true, detail: "moved to get /pets/{petId}/{tag}"}] =
               Drift.compare(base(), moved)
    end

    test "parameter changes, with $refs resolved" do
      new_list =
        Map.put(@list, "parameters", [
          %{
            "name" => "limit",
            "in" => "query",
            "required" => true,
            "schema" => %{"type" => "string"}
          },
          %{"name" => "cursor", "in" => "query"},
          %{"name" => "region", "in" => "header", "required" => true}
        ])

      changed = put_in(base(), ["paths", "/pets", "get"], new_list)

      assert summary(Drift.compare(base(), changed)) == [
               {:operation, :changed, "get /pets (listPets)", "query parameter cursor added",
                false},
               {:operation, :changed, "get /pets (listPets)",
                "header parameter region added, required", true},
               {:operation, :changed, "get /pets (listPets)",
                "query parameter limit is now required", true},
               {:operation, :changed, "get /pets (listPets)",
                "query parameter limit: type integer → string", true}
             ]
    end

    test "request body and response changes" do
      body = %{
        "required" => true,
        "content" => %{
          "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Pet"}}
        }
      }

      with_body = put_in(base(), ["paths", "/pets", "get", "requestBody"], body)

      assert [%{detail: "request body added, required", breaking?: true}] =
               Drift.compare(base(), with_body)

      assert [%{detail: "request body removed", breaking?: true}] =
               Drift.compare(with_body, base())

      responses = put_in(@show, ["responses", "404"], %{"description" => "gone"})
      more = put_in(base(), ["paths", "/pets/{id}", "get"], responses)

      assert [%{detail: "response 404 added", breaking?: false}] = Drift.compare(base(), more)
      assert [%{detail: "response 404 removed", breaking?: true}] = Drift.compare(more, base())

      inline =
        put_in(@show, ["responses", "200", "content", "application/json", "schema"], %{
          "type" => "array"
        })

      assert [%{detail: "response 200 application/json: $ref Pet → (inline)"}] =
               Drift.compare(base(), put_in(base(), ["paths", "/pets/{id}", "get"], inline))
    end

    test "request body: optional added, required flips, content changes, $ref'd bodies" do
      pet_body = fn required ->
        %{
          "required" => required,
          "content" => %{
            "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Pet"}}
          }
        }
      end

      with_body = fn body -> put_in(base(), ["paths", "/pets", "get", "requestBody"], body) end

      assert [%{detail: "request body added", breaking?: false}] =
               Drift.compare(base(), with_body.(pet_body.(false)))

      assert [%{detail: "request body is now required", breaking?: true}] =
               Drift.compare(with_body.(pet_body.(false)), with_body.(pet_body.(true)))

      assert [%{detail: "request body is no longer required", breaking?: false}] =
               Drift.compare(with_body.(pet_body.(true)), with_body.(pet_body.(false)))

      xml = put_in(pet_body.(false), ["content", "application/xml"], %{})

      assert [%{detail: "request body application/xml added", breaking?: false}] =
               Drift.compare(with_body.(pet_body.(false)), with_body.(xml))

      inline =
        put_in(pet_body.(false), ["content", "application/json", "schema"], %{"type" => "object"})

      assert [%{detail: "request body application/json: $ref Pet → (inline)", breaking?: true}] =
               Drift.compare(with_body.(pet_body.(false)), with_body.(inline))

      referenced =
        base()
        |> put_in(["components", "requestBodies"], %{"PetBody" => pet_body.(true)})
        |> put_in(["paths", "/pets", "get", "requestBody"], %{
          "$ref" => "#/components/requestBodies/PetBody"
        })

      assert [%{detail: "request body is no longer required"}] =
               Drift.compare(referenced, with_body.(pet_body.(false)))
    end

    test "component schema changes are reported per schema" do
      child = %{"type" => "object"}
      pet = put_in(@pet, ["properties", "childRate"], %{"$ref" => "#/components/schemas/Child"})
      newer = put_in(base(), ["components", "schemas"], %{"Pet" => pet, "Child" => child})

      assert summary(Drift.compare(base(), newer)) == [
               {:schema, :added, "Child", nil, false},
               {:schema, :changed, "Pet", "property childRate added", false}
             ]

      assert summary(Drift.compare(newer, base())) == [
               {:schema, :removed, "Child", nil, true},
               {:schema, :changed, "Pet", "property childRate removed", true}
             ]
    end

    test "ignores documentation-only changes" do
      documented =
        base()
        |> put_in(["paths", "/pets", "get", "summary"], "List all pets")
        |> put_in(["components", "schemas", "Pet", "description"], "A pet")

      assert Drift.compare(base(), documented) == []
    end
  end

  describe "breaking?/1" do
    test "is true when any change is breaking" do
      refute Drift.breaking?([%{breaking?: false}])
      assert Drift.breaking?([%{breaking?: false}, %{breaking?: true}])
    end
  end
end
