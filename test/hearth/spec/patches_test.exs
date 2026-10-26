defmodule Hearth.Spec.PatchesTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Patches

  @spec_map %{
    "swagger" => "2.0",
    "paths" => %{
      "/blocks/{id}" => %{
        "get" => %{
          "operationId" => "getBlock",
          "deprecated" => true,
          "parameters" => [%{"name" => "id", "in" => "path"}]
        }
      }
    }
  }

  @bearer %{"type" => "http", "scheme" => "bearer"}

  defp apply_patches(patches, spec \\ @spec_map) do
    {:ok, parsed} = Patches.parse(patches)
    Patches.apply(spec, parsed)
  end

  describe "parse/1" do
    test "no patches" do
      assert Patches.parse(%{}) == {:ok, []}
    end

    test "a pointer must start with /" do
      assert {:error, message} = Patches.parse(%{"components" => %{}})
      assert message =~ ~s|"components"|
      assert message =~ "JSON pointer"
    end

    test "replacing the whole document isn't a patch" do
      assert {:error, message} = Patches.parse(%{"" => %{}})
      assert message =~ "JSON pointer"
    end

    test "must be a map" do
      assert {:error, message} = Patches.parse([{"/security", []}])
      assert message =~ "`overrides: [patches: …]` maps JSON pointers to values"
    end

    test "values are JSON: string keys, no atoms beyond true / false / nil" do
      assert {:error, message} = Patches.parse(%{"/components" => %{type: "http"}})
      assert message =~ ~s|"/components"|
      assert message =~ "string keys"

      assert {:error, _} = Patches.parse(%{"/x" => :bearer})
      assert {:ok, _} = Patches.parse(%{"/x" => [1, 2.5, true, false, "s", %{"k" => nil}]})
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
      assert {:ok, spec, []} = apply_patches(%{"/paths/~1blocks~1{id}/get/deprecated" => nil})
      refute Map.has_key?(spec["paths"]["/blocks/{id}"]["get"], "deprecated")
    end

    test "~1 is a / and ~0 a ~ inside a segment" do
      assert {:ok, spec, []} = apply_patches(%{"/info/x~0y~1z" => "v"})
      assert spec["info"]["x~y/z"] == "v"
    end

    test "list items by index, and - appends" do
      base = "/paths/~1blocks~1{id}/get/parameters"

      assert {:ok, spec, []} =
               apply_patches(%{
                 "#{base}/0/description" => "The block id",
                 "#{base}/-" => %{"name" => "x-hotelid", "in" => "header"}
               })

      [id, hotel] = spec["paths"]["/blocks/{id}"]["get"]["parameters"]
      assert id["description"] == "The block id"
      assert hotel["name"] == "x-hotelid"
    end

    test "nil on a list index removes the item" do
      assert {:ok, spec, []} = apply_patches(%{"/paths/~1blocks~1{id}/get/parameters/0" => nil})
      assert spec["paths"]["/blocks/{id}"]["get"]["parameters"] == []
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
      assert {:error, message} = apply_patches(%{"/paths/~1blocks~1{id}/get/parameters/5" => %{}})
      assert message =~ "no item 5"
    end

    test "applies in pointer order, so a later patch can build on an earlier one" do
      assert {:ok, spec, []} =
               apply_patches(%{"/security" => [], "/security/-" => %{"bearerAuth" => []}})

      assert spec["security"] == [%{"bearerAuth" => []}]
    end
  end
end
