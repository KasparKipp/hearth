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

  describe "apply/2 appending with -" do
    @enum_spec %{"components" => %{"schemas" => %{"Status" => %{"enum" => ["open", "closed"]}}}}
    @enum "/components/schemas/Status/enum/-"

    test "a value the list already holds is stale, and isn't appended again" do
      assert {:ok, spec, stale} = apply_patches(%{@enum => "closed"}, @enum_spec)
      assert spec == @enum_spec
      assert stale == [{:patches, ~s|"#{@enum}" (already in the source)|}]
    end

    test "a value the list doesn't hold is appended" do
      assert {:ok, spec, []} = apply_patches(%{@enum => "archived"}, @enum_spec)
      assert spec["components"]["schemas"]["Status"]["enum"] == ["open", "closed", "archived"]
    end

    test "a security requirement equal to one there is stale; a different one is appended" do
      spec = %{"security" => [%{"bearerAuth" => []}]}

      assert {:ok, ^spec, [{:patches, ~s|"/security/-" (already in the source)|}]} =
               apply_patches(%{"/security/-" => %{"bearerAuth" => []}}, spec)

      assert {:ok, patched, []} = apply_patches(%{"/security/-" => %{"apiKey" => []}}, spec)
      assert patched["security"] == [%{"bearerAuth" => []}, %{"apiKey" => []}]
    end

    test "a parameter equal to one there is stale" do
      pointer = "/paths/~1items~1{id}/get/parameters/-"

      assert {:ok, spec, [{:patches, why}]} =
               apply_patches(%{pointer => %{"name" => "id", "in" => "path"}})

      assert spec == @spec_map
      assert why == ~s|"#{pointer}" (already in the source)|
    end

    test "matches exactly: 1.0 isn't the 1 already there" do
      assert {:ok, %{"a" => [1, 1.0]}, []} = apply_patches(%{"/a/-" => 1.0}, %{"a" => [1]})
    end

    test "onto a missing key creates the list" do
      assert {:ok, %{"a" => ["v"]}, []} = apply_patches(%{"/a/-" => "v"}, %{})
    end

    test "through missing maps creates them, then the list" do
      assert {:ok, %{"x" => %{"y" => ["v"]}}, []} = apply_patches(%{"/x/y/-" => "v"}, %{})
    end

    test "a map with a literal - key keeps it as a key" do
      assert {:ok, %{"a" => %{"-" => "v"}}, []} = apply_patches(%{"/a/-" => "v"}, %{"a" => %{}})
    end

    test "onto what an earlier patch set: stale when that list holds the value" do
      assert {:ok, %{"a" => ["x", "y"]}, [{:patches, ~s|"/a/-" (already in the source)|}]} =
               apply_patches(%{"/a" => ["x", "y"], "/a/-" => "y"}, %{})
    end

    test "can't go through - to a key below it" do
      assert {:error, message} = apply_patches(%{"/a/-/b" => "v"}, %{"a" => []})
      assert message =~ "no item -"
    end
  end
end
