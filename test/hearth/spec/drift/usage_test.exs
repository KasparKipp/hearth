defmodule Hearth.Spec.Drift.UsageTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Drift.Usage

  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
  defp json(schema), do: %{"content" => %{"application/json" => %{"schema" => schema}}}

  defp spec(operation, schemas, components \\ %{}) do
    %{
      "paths" => %{"/pets" => %{"post" => operation}},
      "components" => Map.put(components, "schemas", schemas)
    }
  end

  describe "sides/1" do
    test "parameters and request bodies are request roots, responses response roots" do
      op = %{
        "parameters" => [%{"name" => "q", "in" => "query", "schema" => ref("Query")}],
        "requestBody" => json(ref("NewPet")),
        "responses" => %{"200" => json(ref("Pet"))}
      }

      schemas = %{"Query" => %{}, "NewPet" => %{}, "Pet" => %{}, "Unused" => %{}}

      assert Usage.sides(spec(op, schemas)) == %{
               "Query" => :request,
               "NewPet" => :request,
               "Pet" => :response
             }
    end

    test "path-level parameters are request roots" do
      spec =
        put_in(spec(%{}, %{"Id" => %{}}), ["paths", "/pets", "parameters"], [
          %{"name" => "id", "in" => "path", "schema" => ref("Id")}
        ])

      assert Usage.sides(spec) == %{"Id" => :request}
    end

    test "refs are followed transitively, through other components" do
      op = %{
        "requestBody" => %{"$ref" => "#/components/requestBodies/PetBody"},
        "responses" => %{"200" => %{"$ref" => "#/components/responses/PetList"}}
      }

      schemas = %{
        "Pet" => %{"properties" => %{"owner" => ref("Owner")}},
        "Owner" => %{"items" => ref("Address")},
        "Address" => %{},
        "Page" => %{"allOf" => [ref("Address")]}
      }

      components = %{
        "requestBodies" => %{"PetBody" => json(ref("Pet"))},
        "responses" => %{"PetList" => json(ref("Page"))}
      }

      assert Usage.sides(spec(op, schemas, components)) == %{
               "Pet" => :request,
               "Owner" => :request,
               "Address" => :both,
               "Page" => :response
             }
    end

    test "cycles end" do
      op = %{"responses" => %{"200" => json(ref("Node"))}}

      schemas = %{
        "Node" => %{"properties" => %{"children" => %{"items" => ref("Node")}, "x" => ref("X")}},
        "X" => %{"properties" => %{"back" => ref("Node")}}
      }

      assert Usage.sides(spec(op, schemas)) == %{"Node" => :response, "X" => :response}
    end

    test "unresolvable and non-local refs are skipped" do
      op = %{
        "requestBody" => json(ref("Missing")),
        "responses" => %{"200" => json(%{"$ref" => "other.yaml#/Pet"})}
      }

      assert Usage.sides(spec(op, %{})) == %{"Missing" => :request}
    end
  end

  describe "union/2 and side/2" do
    test "a name on different sides is on both" do
      a = %{"A" => :request, "B" => :response}
      b = %{"A" => :response, "C" => :request, "B" => :response}

      assert Usage.union(a, b) == %{"A" => :both, "B" => :response, "C" => :request}
    end

    test "an unreferenced name is on both sides" do
      assert Usage.side(%{"A" => :request}, "A") == :request
      assert Usage.side(%{"A" => :request}, "Z") == :both
    end

    test "rename/2 folds copies into their plain names" do
      sides = %{"items_Pet" => :request, "orders_Pet" => :response, "Other" => :request}
      pairs = %{"items_Pet" => {:items, "Pet"}, "orders_Pet" => {:orders, "Pet"}}

      assert Usage.rename(sides, pairs) == %{"Pet" => :both, "Other" => :request}
    end
  end
end
