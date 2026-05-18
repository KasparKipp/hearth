defmodule Hearth.Spec.PruneTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Operation
  alias Hearth.Spec.Prune

  defp op(method, path) do
    struct(Operation, method: method, path: path, path_params: [], tags: [])
  end

  @spec_map %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "T", "version" => "1"},
    "servers" => [%{"url" => "https://x"}],
    "paths" => %{
      "/search" => %{
        "post" => %{
          "responses" => %{
            "200" => %{
              "content" => %{
                "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Result"}}
              }
            }
          }
        }
      },
      "/submit" => %{
        "post" => %{
          "requestBody" => %{
            "content" => %{
              "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Unused"}}
            }
          }
        }
      },
      "/notices/{id}" => %{
        "get" => %{"summary" => "get"},
        "delete" => %{"summary" => "del"},
        "parameters" => [%{"name" => "id", "in" => "path"}]
      }
    },
    "components" => %{
      "schemas" => %{
        "Result" => %{"allOf" => [%{"$ref" => "#/components/schemas/Item"}]},
        "Item" => %{"type" => "object"},
        "Unused" => %{"type" => "object"}
      },
      "securitySchemes" => %{"token" => %{"type" => "http", "scheme" => "bearer"}}
    }
  }

  describe "prune/2 — paths" do
    test "keeps only the selected operations' paths" do
      pruned = Prune.prune(@spec_map, [op(:post, "/search")])
      assert Map.keys(pruned["paths"]) == ["/search"]
    end

    test "within a path, keeps only the selected methods plus path-level keys" do
      pruned = Prune.prune(@spec_map, [op(:get, "/notices/{id}")])
      item = pruned["paths"]["/notices/{id}"]

      assert Map.has_key?(item, "get")
      refute Map.has_key?(item, "delete")
      assert Map.has_key?(item, "parameters")
    end

    test "info / servers / openapi are kept untouched" do
      pruned = Prune.prune(@spec_map, [op(:post, "/search")])

      assert pruned["info"] == @spec_map["info"]
      assert pruned["servers"] == @spec_map["servers"]
      assert pruned["openapi"] == "3.0.0"
    end
  end

  describe "prune/2 — components" do
    test "keeps only $ref-reachable schemas, transitively through allOf" do
      pruned = Prune.prune(@spec_map, [op(:post, "/search")])

      assert pruned["components"]["schemas"] |> Map.keys() |> Enum.sort() == ["Item", "Result"]
      refute Map.has_key?(pruned["components"]["schemas"], "Unused")
    end

    test "securitySchemes are kept whole" do
      pruned = Prune.prune(@spec_map, [op(:post, "/search")])

      assert pruned["components"]["securitySchemes"] ==
               @spec_map["components"]["securitySchemes"]
    end

    test "a section that prunes to empty is dropped" do
      # /notices/{id} carries no $ref → no schemas reachable
      pruned = Prune.prune(@spec_map, [op(:get, "/notices/{id}")])

      refute Map.has_key?(pruned["components"], "schemas")
      assert Map.has_key?(pruned["components"], "securitySchemes")
    end

    test "a spec with no components stays componentless" do
      pruned = Prune.prune(Map.delete(@spec_map, "components"), [op(:post, "/search")])
      refute Map.has_key?(pruned, "components")
    end
  end

  describe "to_yaml/1" do
    defp at(yaml, needle), do: yaml |> :binary.match(needle) |> elem(0)

    test "emits top-level keys in conventional order, not alphabetical" do
      yaml = Prune.to_yaml(@spec_map)

      # conventional: openapi → info → servers → paths → components;
      # alphabetical would put `components` first.
      assert at(yaml, "openapi:") < at(yaml, "info:")
      assert at(yaml, "info:") < at(yaml, "paths:")
      assert at(yaml, "paths:") < at(yaml, "components:")
    end

    test "the result is valid YAML that re-parses to the same spec" do
      assert {:ok, @spec_map} == @spec_map |> Prune.to_yaml() |> YamlElixir.read_from_string()
    end
  end
end
