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

    test "a change of auth scheme is breaking" do
      schemes = %{
        "basicAuth" => %{"type" => "http", "scheme" => "basic"},
        "keyAuth" => %{"type" => "apiKey", "in" => "header", "name" => "X-Key"}
      }

      with_auth = fn primary ->
        base()
        |> put_in(["components", "securitySchemes"], schemes)
        |> Map.put("security", [%{primary => []}])
      end

      assert summary(Drift.compare(with_auth.("basicAuth"), with_auth.("keyAuth"))) == [
               {:auth, :changed, "auth", "basic → API key in header X-Key", true}
             ]

      assert Drift.compare(with_auth.("keyAuth"), with_auth.("keyAuth")) == []
    end

    test "ignores documentation-only changes" do
      documented =
        base()
        |> put_in(["paths", "/pets", "get", "summary"], "List all pets")
        |> put_in(["components", "schemas", "Pet", "description"], "A pet")

      assert Drift.compare(base(), documented) == []
    end
  end

  # `sources:` merges split a component per source (`Pet` → `items_Pet`,
  # `orders_Pet`) when the copies stop matching, and join them back when
  # they match again. The generated code never names a schema.
  describe "compare/3 with a merge" do
    @merge [keys: [:items, :orders], splits: [{"schemas", "Pet"}]]
    @tag_prop %{"tag" => %{"type" => "string"}}

    defp pet_at(spec, name) do
      put_in(
        spec,
        ["paths", "/pets/{id}", "get", "responses", "200", "content", "application/json"],
        %{"schema" => %{"$ref" => "#/components/schemas/#{name}"}}
      )
    end

    defp tagged, do: put_in(@pet, ["properties"], Map.merge(@pet["properties"], @tag_prop))

    defp split do
      base()
      |> put_in(["components", "schemas"], %{"items_Pet" => @pet, "orders_Pet" => tagged()})
      |> pet_at("items_Pet")
    end

    test "a split is one non-breaking line, then each copy's own changes" do
      assert summary(Drift.compare(base(), split(), @merge)) == [
               {:schema, :changed, "Pet", "split per source into items_Pet, orders_Pet", false},
               {:schema, :changed, "orders_Pet", "property tag added", false}
             ]
    end

    test "a join is one non-breaking line, then what each copy lost or gained" do
      assert summary(Drift.compare(split(), base(), @merge)) == [
               {:schema, :changed, "Pet", "joined from items_Pet, orders_Pet", false},
               {:schema, :changed, "Pet", "from orders_Pet: property tag removed", true}
             ]
    end

    test "a copy split off a name its keeper still holds" do
      kept =
        put_in(base(), ["components", "schemas"], %{"Pet" => @pet, "orders_Pet" => tagged()})

      assert summary(Drift.compare(base(), kept, @merge)) == [
               {:schema, :changed, "Pet", "orders_Pet split off from it", false},
               {:schema, :changed, "orders_Pet", "property tag added", false}
             ]
    end

    test "refs inside the copies follow the pairing" do
      owner = fn name -> %{"type" => "object", "properties" => %{"pet" => %{"$ref" => name}}} end

      old =
        put_in(base(), ["components", "schemas", "Owner"], owner.("#/components/schemas/Pet"))

      new =
        split()
        |> put_in(
          ["components", "schemas", "items_Owner"],
          owner.("#/components/schemas/items_Pet")
        )
        |> put_in(
          ["components", "schemas", "orders_Owner"],
          owner.("#/components/schemas/orders_Pet")
        )

      merge = Keyword.update!(@merge, :splits, &[{"schemas", "Owner"} | &1])
      refute Drift.breaking?(Drift.compare(old, new, merge))
    end

    # `shared:` moves `Pet` from items to orders: items' copy splits off
    # and orders' copy joins it, each compared with what its source had.
    defp pinned(pet, other, copy),
      do: put_in(base(), ["components", "schemas"], %{"Pet" => pet, "#{other}_Pet" => copy})

    test "a pin moving between sources compares each source with itself" do
      old = pinned(@pet, :orders, tagged())
      new = pinned(tagged(), :items, @pet)

      assert summary(Drift.compare(old, new, @merge)) == [
               {:schema, :changed, "Pet", "items_Pet split off from it; orders_Pet joined it",
                false}
             ]

      assert summary(Drift.compare(old, pinned(@pet, :items, @pet), @merge)) == [
               {:schema, :changed, "Pet", "items_Pet split off from it; orders_Pet joined it",
                false},
               {:schema, :changed, "Pet", "from orders_Pet: property tag removed", true}
             ]
    end

    test "a schema named like a copy, but not one the merge split, stays itself" do
      status = %{"type" => "string"}

      old = put_in(base(), ["components", "schemas", "status"], status)
      new = put_in(old, ["components", "schemas", "items_status"], status)

      assert summary(Drift.compare(old, new, @merge)) == [
               {:schema, :added, "items_status", nil, false}
             ]
    end

    test "only the copies the pruned spec reaches" do
      partial = put_in(base(), ["components", "schemas"], %{"orders_Pet" => tagged()})

      assert summary(Drift.compare(base(), partial, @merge)) == [
               {:schema, :changed, "Pet", "split per source into orders_Pet", false},
               {:schema, :changed, "orders_Pet", "property tag added", false}
             ]
    end

    test "a join goes by the longest source key a copy starts with" do
      merge = [keys: [:a, :a_b]]
      old = put_in(base(), ["components", "schemas"], %{"a_b_Pet" => tagged(), "b_Pet" => @pet})
      new = put_in(base(), ["components", "schemas"], %{"Pet" => @pet, "b_Pet" => @pet})

      assert summary(Drift.compare(old, new, merge)) == [
               {:schema, :changed, "Pet", "joined from a_b_Pet", false},
               {:schema, :changed, "Pet", "from a_b_Pet: property tag removed", true}
             ]
    end

    test "without source keys, names are compared as they are" do
      assert {:schema, :removed, "Pet", nil, true} in summary(Drift.compare(base(), split()))
    end
  end

  describe "breaking?/1" do
    test "is true when any change is breaking" do
      refute Drift.breaking?([%{breaking?: false}])
      assert Drift.breaking?([%{breaking?: false}, %{breaking?: true}])
    end
  end
end
