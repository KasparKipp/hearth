defmodule Hearth.Spec.SelectionTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Operation
  alias Hearth.Spec.Selection

  # pets: listPets, createPets, showPetById · store: getInventory ·
  # users: getUser, listUsers · getUser is tagged users AND admin ·
  # health has no tags and no operationId.
  @spec_map %{
    "paths" => %{
      "/pets" => %{
        "get" => %{"operationId" => "listPets", "tags" => ["pets"]},
        "post" => %{"operationId" => "createPets", "tags" => ["pets"]}
      },
      "/pets/{petId}" => %{"get" => %{"operationId" => "showPetById", "tags" => ["pets"]}},
      "/store/inventory" => %{"get" => %{"operationId" => "getInventory", "tags" => ["store"]}},
      "/users" => %{"get" => %{"operationId" => "listUsers", "tags" => ["users"]}},
      "/users/{id}" => %{"get" => %{"operationId" => "getUser", "tags" => ["users", "admin"]}},
      "/health" => %{"get" => %{}}
    }
  }

  defp operations, do: Operation.extract(@spec_map)

  defp pick(ids), do: Enum.filter(operations(), &(&1.operation_id in ids))

  describe "describe/2" do
    test "a partly selected tag lists what's included and what's excluded" do
      result = Selection.describe(operations(), pick(["listPets"]))

      assert result[:tags][:pets] == [
               include: ["listPets"],
               exclude: ["createPets", "showPetById"]
             ]
    end

    test "a fully selected tag is :all, an unselected one :none" do
      result = Selection.describe(operations(), pick(["getInventory"]))

      assert result[:tags][:store] == :all
      assert result[:tags][:pets] == :none
    end

    test "lists every tag in the spec, in first-seen operation order" do
      result = Selection.describe(operations(), pick(["listPets"]))

      assert Keyword.keys(result[:tags]) == [:pets, :store, :users, :admin]
    end

    test "an operation tagged twice counts under both tags" do
      result = Selection.describe(operations(), pick(["getUser"]))

      assert result[:tags][:users] == [include: ["getUser"], exclude: ["listUsers"]]
      assert result[:tags][:admin] == :all
    end

    test "untagged operations are recorded under :untagged, by derived id without an operationId" do
      assert Selection.describe(operations(), pick(["listPets"]))[:untagged] == :none
      assert Selection.describe(operations(), operations())[:untagged] == :all

      partial = %{
        "paths" => %{
          "/health" => %{"get" => %{}},
          "/ping" => %{"get" => %{"operationId" => "ping"}}
        }
      }

      ops = Operation.extract(partial)
      selected = Enum.filter(ops, &(&1.operation_id == "ping"))

      assert Selection.describe(ops, selected)[:untagged] ==
               [include: ["ping"], exclude: ["get_health"]]
    end

    test "omits :untagged when every operation has a tag" do
      ops = Enum.reject(operations(), &(&1.tags == []))

      refute Keyword.has_key?(Selection.describe(ops, ops), :untagged)
    end

    test "a tag name that isn't a plain atom still round-trips through .hearth.exs" do
      spec = %{
        "paths" => %{"/a" => %{"get" => %{"operationId" => "a", "tags" => ["Customer Accounts"]}}}
      }

      ops = Operation.extract(spec)
      result = Selection.describe(ops, ops)

      assert result[:tags] == [{:"Customer Accounts", :all}]
    end
  end
end
