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

  describe "rule/1" do
    test "reads tags: and untagged: from an entry" do
      entry = [module: X, tags: [pets: :all, "Customer Accounts": :none], untagged: :all]

      assert {:ok, rule} = Selection.rule(entry)
      assert rule.tags == %{"pets" => :all, "Customer Accounts" => :none}
      assert rule.untagged == :all
    end

    test "an entry without tags: has no rule" do
      assert Selection.rule(module: X) == :none
    end
  end

  describe "select/2" do
    defp rule!(entry) do
      {:ok, rule} = Selection.rule(entry)
      rule
    end

    defp ids(operations), do: Enum.map(operations, & &1.operation_id)

    test "selects :all tags, include: lists, and untagged operations per untagged:" do
      rule =
        rule!(tags: [pets: [include: ["listPets"], exclude: []], store: :all], untagged: :all)

      assert operations() |> Selection.select(rule) |> ids() |> Enum.sort() ==
               [nil, "getInventory", "listPets"]
    end

    test "an operation is selected when any of its tags selects it" do
      rule = rule!(tags: [users: :none, admin: :all])

      assert operations() |> Selection.select(rule) |> ids() == ["getUser"]
    end

    test "a tag the rule doesn't mention selects nothing" do
      assert operations() |> Selection.select(rule!(tags: [])) |> ids() == []
    end

    test "is the inverse of describe/2" do
      selected = pick(["listPets", "getUser", "getInventory"])
      rule = rule!(Selection.describe(operations(), selected))

      assert Selection.select(operations(), rule) == selected
    end
  end

  describe "check/2" do
    defp pruned(ids), do: pick(ids)

    test "a pruned spec matching the rule has no problems" do
      selected = pick(["listPets", "getInventory"])
      rule = rule!(Selection.describe(operations(), selected))

      assert Selection.check(rule, selected) == []
    end

    test "an included operation missing from the pruned spec is a problem" do
      rule = rule!(tags: [pets: [include: ["listPets", "createPets"], exclude: ["showPetById"]]])

      assert [problem] = Selection.check(rule, pruned(["listPets"]))
      assert problem =~ "createPets"
    end

    test "a pruned operation the rule doesn't select is a problem" do
      rule = rule!(tags: [pets: [include: ["listPets"], exclude: ["createPets"]]])

      assert [problem] = Selection.check(rule, pruned(["listPets", "createPets"]))
      assert problem =~ "createPets"
    end

    test "an :all tag with none of its operations pruned is a problem" do
      rule = rule!(tags: [pets: :all, store: :all])

      assert [problem] = Selection.check(rule, pruned(["listPets", "createPets", "showPetById"]))
      assert problem =~ "store"
    end
  end

  describe "unlisted/2" do
    test "lists unselected operations that tags: doesn't mention: new tags, and new ids under a partial tag" do
      rule = rule!(tags: [pets: [include: ["listPets"], exclude: ["createPets"]], users: :all])

      unlisted = operations() |> Selection.unlisted(rule) |> ids()

      # showPetById: not in pets' lists · getInventory: store is unknown ·
      # health: untagged, and the rule has no untagged:
      assert Enum.sort(unlisted) == [nil, "getInventory", "showPetById"]
    end

    test "a :none tag or an exclude: entry is a decision, not news" do
      rule =
        rule!(
          tags: [
            pets: [include: ["listPets"], exclude: ["createPets", "showPetById"]],
            store: :none,
            users: :all,
            admin: :none
          ],
          untagged: :none
        )

      assert Selection.unlisted(operations(), rule) == []
    end
  end

  describe "carry_renames/3" do
    defp renamed(operations, old_id, new_id) do
      Enum.map(operations, fn
        %{operation_id: ^old_id} = op -> %{op | operation_id: new_id}
        op -> op
      end)
    end

    test "points include: and exclude: at an operation's new name, matched by method + path" do
      rule = rule!(tags: [pets: [include: ["listPets"], exclude: ["createPets", "showPetById"]]])

      source =
        operations() |> renamed("listPets", "listAllPets") |> renamed("createPets", "addPet")

      carried = Selection.carry_renames(rule, operations(), source)

      assert carried.tags["pets"] == [
               include: ["listAllPets"],
               exclude: ["addPet", "showPetById"]
             ]

      assert source |> Selection.select(carried) |> ids() == ["listAllPets"]
    end

    test "leaves the rule alone when nothing was renamed" do
      rule = rule!(tags: [pets: :all, users: [include: ["getUser"], exclude: ["listUsers"]]])

      assert Selection.carry_renames(rule, operations(), operations()) == rule
    end
  end
end
