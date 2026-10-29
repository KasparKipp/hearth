defmodule Hearth.Spec.MergeTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Merge

  # Two modules of one API behind one host: a base path each, a shared
  # parameter, and a schema name both use for different shapes.
  defp items(server \\ "/items/v1") do
    %{
      "openapi" => "3.0.3",
      "info" => %{"title" => "Items API", "version" => "1.2"},
      "servers" => [%{"url" => server}],
      "tags" => [%{"name" => "Items"}],
      "security" => [%{"bearerAuth" => []}],
      "paths" => %{
        "/items/{id}" => %{
          "get" => %{
            "operationId" => "getItem",
            "parameters" => [%{"$ref" => "#/components/parameters/tenant"}],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/item"}}
                }
              }
            }
          }
        }
      },
      "components" => %{
        "parameters" => %{"tenant" => %{"name" => "x-tenant", "in" => "header"}},
        "schemas" => %{
          "item" => %{
            "type" => "object",
            "properties" => %{"address" => %{"$ref" => "#/components/schemas/address"}}
          },
          "address" => %{"type" => "object", "properties" => %{"street" => %{"type" => "string"}}},
          "money" => %{"type" => "number"}
        },
        "securitySchemes" => %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}}
      }
    }
  end

  defp orders(server \\ "/orders/v1") do
    %{
      "openapi" => "3.0.3",
      "info" => %{"title" => "Orders API", "version" => "1.2"},
      "servers" => [%{"url" => server}],
      "tags" => [%{"name" => "Orders"}],
      "security" => [%{"bearerAuth" => []}],
      "paths" => %{
        "/orders/{id}" => %{
          "get" => %{
            "operationId" => "getOrder",
            "parameters" => [%{"$ref" => "#/components/parameters/tenant"}],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "shipment" => %{"$ref" => "#/components/schemas/shipment"},
                        "price" => %{"$ref" => "#/components/schemas/money"}
                      }
                    }
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "parameters" => %{"tenant" => %{"name" => "x-tenant", "in" => "header"}},
        "schemas" => %{
          "shipment" => %{
            "type" => "object",
            "properties" => %{"address" => %{"$ref" => "#/components/schemas/address"}}
          },
          "address" => %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}},
          "money" => %{"type" => "number"}
        },
        "securitySchemes" => %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}}
      }
    }
  end

  defp merge(sources \\ [items: items(), orders: orders()]) do
    {:ok, merged, _splits} = Merge.merge(sources)
    merged
  end

  describe "paths and servers" do
    test "each source's server path moves into its paths" do
      assert merged_paths(merge()) == ["/items/v1/items/{id}", "/orders/v1/orders/{id}"]
    end

    test "no host anywhere: no servers, so the client gets a placeholder" do
      refute Map.has_key?(merge(), "servers")
    end

    test "a shared host stays the one server" do
      merged =
        merge(
          items: items("https://gw.test/items/v1"),
          orders: orders("https://gw.test/orders/v1/")
        )

      assert merged["servers"] == [%{"url" => "https://gw.test"}]
      assert merged_paths(merged) == ["/items/v1/items/{id}", "/orders/v1/orders/{id}"]
    end

    test "different hosts halt: one client has one base URL" do
      assert {:error, message} =
               Merge.merge(items: items("https://a.test/v1"), orders: orders("https://b.test/v1"))

      assert message =~ "https://a.test"
      assert message =~ "https://b.test"
    end

    test "a path both sources have halts" do
      assert {:error, message} = Merge.merge(items: items("/v1"), again: items("/v1"))
      assert message =~ ~s|"/v1/items/{id}"|
      assert message =~ "items"
      assert message =~ "again"
    end

    test "an operationId both sources use halts" do
      clash = put_in(orders(), ["paths", "/orders/{id}", "get", "operationId"], "getItem")

      assert {:error, message} = Merge.merge(items: items(), orders: clash)
      assert message =~ ~s|"getItem"|
    end
  end

  describe "components" do
    test "identical components are kept once, unprefixed" do
      components = merge()["components"]

      assert components["parameters"] == %{"tenant" => %{"name" => "x-tenant", "in" => "header"}}
      assert components["schemas"]["money"] == %{"type" => "number"}
      assert Map.keys(components["securitySchemes"]) == ["bearerAuth"]
    end

    test "same-named components that differ get their source's key, refs follow" do
      merged = merge()
      schemas = merged["components"]["schemas"]

      refute Map.has_key?(schemas, "address")
      assert schemas["items_address"]["properties"]["street"]
      assert schemas["orders_address"]["properties"]["city"]

      assert schemas["item"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/items_address"
             }

      assert schemas["shipment"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/orders_address"
             }
    end

    test "returns the components it split" do
      assert {:ok, _merged, [{"schemas", "address"}]} =
               Merge.merge(items: items(), orders: orders())
    end

    test "keep: pins the plain name to one source; only the others are prefixed, still a split" do
      assert {:ok, merged, [{"schemas", "address"}]} =
               Merge.merge([items: items(), orders: orders()], %{{"schemas", "address"} => :items})

      schemas = merged["components"]["schemas"]
      assert schemas["address"]["properties"]["street"]
      assert schemas["orders_address"]["properties"]["city"]
      refute Map.has_key?(schemas, "items_address")

      assert schemas["item"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/address"
             }

      assert schemas["shipment"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/orders_address"
             }
    end

    test "components that differ only in docs are kept once, as the first source has it" do
      documented = fn spec, text ->
        spec
        |> put_in(["components", "schemas", "money", "description"], text)
        |> put_in(["components", "schemas", "money", "example"], 1)
        |> put_in(["components", "parameters", "tenant", "description"], text)
      end

      assert {:ok, merged, [{"schemas", "address"}]} =
               Merge.merge(
                 items: documented.(items(), "Item price."),
                 orders: documented.(orders(), "Order total.")
               )

      components = merged["components"]
      assert components["schemas"]["money"]["description"] == "Item price."
      assert components["parameters"]["tenant"]["description"] == "Item price."
      refute Map.has_key?(components["schemas"], "items_money")
    end

    test "docs nested in a component don't split it either" do
      line = fn spec, text ->
        put_in(spec, ["components", "schemas", "line"], %{
          "type" => "object",
          "title" => text,
          "properties" => %{"qty" => %{"type" => "integer", "description" => text}}
        })
      end

      assert {:ok, merged, [{"schemas", "address"}]} =
               Merge.merge(
                 items: line.(items(), "Item line"),
                 orders: line.(orders(), "Order line")
               )

      assert merged["components"]["schemas"]["line"]["title"] == "Item line"
    end

    test "a property named like a doc key still counts as shape" do
      note = fn spec, properties ->
        put_in(spec, ["components", "schemas", "note"], %{
          "type" => "object",
          "properties" => properties
        })
      end

      assert {:ok, merged, splits} =
               Merge.merge(
                 items: note.(items(), %{"description" => %{"type" => "string"}}),
                 orders: note.(orders(), %{})
               )

      assert {"schemas", "note"} in splits
      assert merged["components"]["schemas"]["items_note"]["properties"]["description"]
    end

    test "names and data that look like doc keys still count as shape" do
      differ = fn component ->
        {:ok, _merged, splits} =
          Merge.merge(
            items: put_in(items(), ["components", "schemas", "x"], component.(:items)),
            orders: put_in(orders(), ["components", "schemas", "x"], component.(:orders))
          )

        {"schemas", "x"} in splits
      end

      ref = &"#/components/schemas/#{&1}"

      assert differ.(&%{"discriminator" => %{"mapping" => %{"title" => ref.(&1)}}})
      assert differ.(&%{"$defs" => %{"summary" => %{"type" => to_string(&1)}}})
      assert differ.(&%{"default" => %{"title" => to_string(&1)}})
      assert differ.(&%{"enum" => [%{"description" => to_string(&1)}]})
      assert differ.(&%{"x-kind" => %{"title" => to_string(&1)}})

      header = fn spec, type ->
        put_in(spec, ["components", "responses"], %{
          "ok" => %{"headers" => %{"title" => %{"schema" => %{"type" => type}}}}
        })
      end

      assert {:ok, _merged, splits} =
               Merge.merge(
                 items: header.(items(), "string"),
                 orders: header.(orders(), "integer")
               )

      assert {"responses", "ok"} in splits
    end

    test "summary and externalDocs are docs too" do
      documented = fn spec, text ->
        put_in(spec, ["components", "schemas", "money"], %{
          "type" => "number",
          "summary" => text,
          "externalDocs" => %{"url" => "https://example.com/#{text}"}
        })
      end

      assert {:ok, _merged, [{"schemas", "address"}]} =
               Merge.merge(items: documented.(items(), "a"), orders: documented.(orders(), "b"))
    end

    test "keep: the pinned source's copy wins when the copies differ only in docs" do
      described = &put_in(&1, ["components", "schemas", "money", "description"], &2)

      assert {:ok, merged, [{"schemas", "address"}]} =
               Merge.merge(
                 [items: described.(items(), "Item."), orders: described.(orders(), "Order.")],
                 %{{"schemas", "address"} => :items, {"schemas", "money"} => :orders}
               )

      assert merged["components"]["schemas"]["money"]["description"] == "Order."
    end

    test "a component that only differs through a renamed ref is split too" do
      shared = %{
        "type" => "object",
        "properties" => %{"at" => %{"$ref" => "#/components/schemas/address"}}
      }

      assert {:ok, merged, splits} =
               Merge.merge(
                 items: put_in(items(), ["components", "schemas", "location"], shared),
                 orders: put_in(orders(), ["components", "schemas", "location"], shared)
               )

      assert Enum.sort(splits) == [{"schemas", "address"}, {"schemas", "location"}]
      schemas = merged["components"]["schemas"]
      refute Map.has_key?(schemas, "location")

      assert schemas["items_location"]["properties"]["at"] == %{
               "$ref" => "#/components/schemas/items_address"
             }

      assert schemas["orders_location"]["properties"]["at"] == %{
               "$ref" => "#/components/schemas/orders_address"
             }
    end
  end

  describe "the rest of the document" do
    test "tags and security are unioned" do
      merged = merge()

      assert merged["tags"] == [%{"name" => "Items"}, %{"name" => "Orders"}]
      assert merged["security"] == [%{"bearerAuth" => []}]
    end

    test "info names every source" do
      assert merge()["info"] == %{"title" => "Items API + Orders API", "version" => "1.2"}

      described = fn spec, text -> put_in(spec, ["info", "description"], text) end

      merged =
        merge(items: described.(items(), "Items."), orders: described.(orders(), "Orders."))

      refute Map.has_key?(merged["info"], "description")

      merged = merge(items: described.(items(), "Same."), orders: described.(orders(), "Same."))
      assert merged["info"]["description"] == "Same."

      newer = put_in(orders(), ["info", "version"], "1.3")
      assert merge(items: items(), orders: newer)["info"]["version"] == "1.2, 1.3"
    end
  end

  defp merged_paths(spec), do: spec["paths"] |> Map.keys() |> Enum.sort()
end
