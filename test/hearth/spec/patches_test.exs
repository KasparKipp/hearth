defmodule Hearth.Spec.PatchesTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Patches

  @spec_map %{
    "swagger" => "2.0",
    "paths" => %{
      "/items/{id}" => %{
        "get" => %{
          "operationId" => "getItem",
          "deprecated" => true,
          "parameters" => [%{"name" => "id", "in" => "path"}]
        }
      }
    }
  }

  @bearer %{"type" => "http", "scheme" => "bearer"}

  defp apply_patches(patches, spec \\ @spec_map) do
    Patches.apply(spec, Patches.parse(patches))
  end

  describe "parse/1" do
    test "sorts by pointer and splits each into unescaped segments" do
      assert Patches.parse(%{"/b/~1x~0y" => 1, "/a" => nil}) ==
               [{"/a", ["a"], nil}, {"/b/~1x~0y", ["b", "/x~y"], 1}]

      assert Patches.parse(%{}) == []
    end
  end

  describe "apply/2" do
    test "sets a value, creating the maps on the way" do
      assert {:ok, spec, []} =
               apply_patches(%{
                 "/components/securitySchemes/bearerAuth" => @bearer,
                 "/security" => [%{"bearerAuth" => []}]
               })

      assert spec["components"]["securitySchemes"]["bearerAuth"] == @bearer
      assert spec["security"] == [%{"bearerAuth" => []}]
    end

    test "nil removes a key" do
      assert {:ok, spec, []} = apply_patches(%{"/paths/~1items~1{id}/get/deprecated" => nil})
      refute Map.has_key?(spec["paths"]["/items/{id}"]["get"], "deprecated")
    end

    test "~1 is a / and ~0 a ~ inside a segment" do
      assert {:ok, spec, []} = apply_patches(%{"/info/x~0y~1z" => "v"})
      assert spec["info"]["x~y/z"] == "v"
    end

    test "list items by index, and - appends" do
      base = "/paths/~1items~1{id}/get/parameters"

      assert {:ok, spec, []} =
               apply_patches(%{
                 "#{base}/0/description" => "The item id",
                 "#{base}/-" => %{"name" => "x-tenant-id", "in" => "header"}
               })

      [id, tenant] = spec["paths"]["/items/{id}"]["get"]["parameters"]
      assert id["description"] == "The item id"
      assert tenant["name"] == "x-tenant-id"
    end

    test "nil on a list index removes the item" do
      assert {:ok, spec, []} = apply_patches(%{"/paths/~1items~1{id}/get/parameters/0" => nil})
      assert spec["paths"]["/items/{id}"]["get"]["parameters"] == []
    end

    test "a value the source already has is stale" do
      assert {:ok, spec, stale} = apply_patches(%{"/swagger" => "2.0", "/nothing" => nil})
      assert spec == @spec_map

      assert stale == [
               {:patches, ~s|"/nothing" (nothing to remove)|},
               {:patches, ~s|"/swagger" (already in the source)|}
             ]
    end

    test "can't go through a value that isn't a map or list" do
      assert {:error, message} = apply_patches(%{"/swagger/version" => "3"})
      assert message =~ ~s|"/swagger/version"|
      assert message =~ ~s|"/swagger" is a string|
    end

    test "a list index must exist" do
      assert {:error, message} = apply_patches(%{"/paths/~1items~1{id}/get/parameters/5" => %{}})
      assert message =~ "no item 5"
    end

    test "applies in pointer order, so a later patch can build on an earlier one" do
      assert {:ok, spec, []} =
               apply_patches(%{"/security" => [], "/security/-" => %{"bearerAuth" => []}})

      assert spec["security"] == [%{"bearerAuth" => []}]
    end
  end
end
