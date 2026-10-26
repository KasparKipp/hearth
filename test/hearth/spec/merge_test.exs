defmodule Hearth.Spec.MergeTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Merge

  # Two modules of one API behind one gateway, like OHIP's Block and
  # Event specs: a base path each, a shared parameter, and a schema
  # name both use for different shapes.
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

  defp events(server \\ "/events/v1") do
    %{
      "openapi" => "3.0.3",
      "info" => %{"title" => "Events API", "version" => "1.2"},
      "servers" => [%{"url" => server}],
      "tags" => [%{"name" => "Events"}],
      "security" => [%{"bearerAuth" => []}],
      "paths" => %{
        "/events/{id}" => %{
          "get" => %{
            "operationId" => "getEvent",
            "parameters" => [%{"$ref" => "#/components/parameters/tenant"}],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "venue" => %{"$ref" => "#/components/schemas/venue"},
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
          "venue" => %{
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

  defp merge(sources \\ [items: items(), events: events()]) do
    {:ok, merged, _splits} = Merge.merge(sources)
    merged
  end

  describe "paths and servers" do
    test "each source's server path moves into its paths" do
      assert merged_paths(merge()) == ["/events/v1/events/{id}", "/items/v1/items/{id}"]
    end

    test "no host anywhere: no servers, so the client gets a placeholder" do
      refute Map.has_key?(merge(), "servers")
    end

    test "a shared host stays the one server" do
      merged =
        merge(
          items: items("https://gw.test/items/v1"),
          events: events("https://gw.test/events/v1/")
        )

      assert merged["servers"] == [%{"url" => "https://gw.test"}]
      assert merged_paths(merged) == ["/events/v1/events/{id}", "/items/v1/items/{id}"]
    end

    test "different hosts halt: one client has one base URL" do
      assert {:error, message} =
               Merge.merge(items: items("https://a.test/v1"), events: events("https://b.test/v1"))

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
      clash = put_in(events(), ["paths", "/events/{id}", "get", "operationId"], "getItem")

      assert {:error, message} = Merge.merge(items: items(), events: clash)
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
      assert schemas["events_address"]["properties"]["city"]

      assert schemas["item"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/items_address"
             }

      assert schemas["venue"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/events_address"
             }
    end

    test "returns the components it split" do
      assert {:ok, _merged, [{"schemas", "address"}]} =
               Merge.merge(items: items(), events: events())
    end

    test "keep: pins the plain name to one source; only the others are prefixed" do
      assert {:ok, merged, []} =
               Merge.merge([items: items(), events: events()], %{{"schemas", "address"} => :items})

      schemas = merged["components"]["schemas"]
      assert schemas["address"]["properties"]["street"]
      assert schemas["events_address"]["properties"]["city"]
      refute Map.has_key?(schemas, "items_address")

      assert schemas["item"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/address"
             }

      assert schemas["venue"]["properties"]["address"] == %{
               "$ref" => "#/components/schemas/events_address"
             }
    end

    test "a component that only differs through a renamed ref is split too" do
      shared = %{
        "type" => "object",
        "properties" => %{"at" => %{"$ref" => "#/components/schemas/address"}}
      }

      assert {:ok, merged, splits} =
               Merge.merge(
                 items: put_in(items(), ["components", "schemas", "location"], shared),
                 events: put_in(events(), ["components", "schemas", "location"], shared)
               )

      assert Enum.sort(splits) == [{"schemas", "address"}, {"schemas", "location"}]
      schemas = merged["components"]["schemas"]
      refute Map.has_key?(schemas, "location")

      assert schemas["items_location"]["properties"]["at"] == %{
               "$ref" => "#/components/schemas/items_address"
             }

      assert schemas["events_location"]["properties"]["at"] == %{
               "$ref" => "#/components/schemas/events_address"
             }
    end
  end

  describe "the rest of the document" do
    test "tags and security are unioned" do
      merged = merge()

      assert merged["tags"] == [%{"name" => "Items"}, %{"name" => "Events"}]
      assert merged["security"] == [%{"bearerAuth" => []}]
    end

    test "info names every source" do
      assert merge()["info"] == %{"title" => "Items API + Events API", "version" => "1.2"}

      described = fn spec, text -> put_in(spec, ["info", "description"], text) end

      merged =
        merge(items: described.(items(), "Items."), events: described.(events(), "Events."))

      refute Map.has_key?(merged["info"], "description")

      merged = merge(items: described.(items(), "Same."), events: described.(events(), "Same."))
      assert merged["info"]["description"] == "Same."

      newer = put_in(events(), ["info", "version"], "1.3")
      assert merge(items: items(), events: newer)["info"]["version"] == "1.2, 1.3"
    end
  end

  defp merged_paths(spec), do: spec["paths"] |> Map.keys() |> Enum.sort()
end
