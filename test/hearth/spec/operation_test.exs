defmodule Hearth.Spec.OperationTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Loader
  alias Hearth.Spec.Operation

  defp load(path) do
    format = Loader.sniff(path)
    {:ok, spec} = path |> File.read!() |> Loader.decode(format)
    spec
  end

  defp by_id(operations, id), do: Enum.find(operations, &(&1.id == id))

  describe "extract/1 — petstore 3.0" do
    setup do
      %{ops: "test/fixtures/specs/petstore-3.0.yaml" |> load() |> Operation.extract()}
    end

    test "extracts every path/method operation", %{ops: ops} do
      assert length(ops) == 3
      assert Enum.map(ops, & &1.id) |> Enum.sort() == ~w(create_pets list_pets show_pet_by_id)
    end

    test "derives snake_case ids from camelCase operationIds", %{ops: ops} do
      assert by_id(ops, "list_pets").operation_id == "listPets"
      assert by_id(ops, "show_pet_by_id").operation_id == "showPetById"
    end

    test "captures method, path, and tags", %{ops: ops} do
      list = by_id(ops, "list_pets")
      assert list.method == :get
      assert list.path == "/pets"
      assert list.tags == ["pets"]
    end

    test "classifies path params", %{ops: ops} do
      show = by_id(ops, "show_pet_by_id")
      assert [%{"name" => "petId", "in" => "path"}] = show.path_params
      assert show.query_params == []
    end

    test "classifies query params", %{ops: ops} do
      list = by_id(ops, "list_pets")
      assert [%{"name" => "limit", "in" => "query"}] = list.query_params
      assert list.path_params == []
    end

    test "captures request body when present", %{ops: ops} do
      assert by_id(ops, "create_pets").request_body["required"] == true
      assert by_id(ops, "list_pets").request_body == nil
    end

    test "captures the summary", %{ops: ops} do
      assert by_id(ops, "list_pets").summary == "List all pets"
    end
  end

  describe "extract/1 — tictactoe 3.1" do
    setup do
      %{ops: "test/fixtures/specs/tictactoe-3.1.yaml" |> load() |> Operation.extract()}
    end

    test "handles 3.1 specs and hyphenated operationIds", %{ops: ops} do
      ids = Enum.map(ops, & &1.id) |> Enum.sort()
      assert "get_board" in ids
      assert "get_square" in ids
      assert "put_square" in ids
    end

    test "hyphenated operationId is preserved verbatim in :operation_id", %{ops: ops} do
      assert by_id(ops, "get_board").operation_id == "get-board"
    end
  end

  describe "extract/1 — id derivation" do
    test "falls back to <verb>_<path-slug> when operationId is absent" do
      spec = %{
        "paths" => %{
          "/entities/{id}/posts" => %{
            "get" => %{"tags" => ["x"]}
          }
        }
      }

      assert [%Operation{id: "get_entities_id_posts", operation_id: nil}] =
               Operation.extract(spec)
    end

    test "resolves collisions with numeric suffixes" do
      # `getUser` and `get_user` both sanitize to `get_user`.
      spec = %{
        "paths" => %{
          "/a" => %{"get" => %{"operationId" => "getUser"}},
          "/b" => %{"get" => %{"operationId" => "get_user"}},
          "/c" => %{"get" => %{"operationId" => "get-user"}}
        }
      }

      ids = spec |> Operation.extract() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ~w(get_user get_user_2 get_user_3)
    end
  end

  describe "tag_index/1" do
    test "groups operations by tag" do
      ops = "test/fixtures/specs/petstore-3.0.yaml" |> load() |> Operation.extract()
      index = Operation.tag_index(ops)

      assert Map.keys(index) == ["pets"]
      assert length(index["pets"]) == 3
    end

    test "collects untagged operations under :untagged" do
      spec = %{"paths" => %{"/a" => %{"get" => %{"operationId" => "getA"}}}}
      index = spec |> Operation.extract() |> Operation.tag_index()

      assert [%Operation{id: "get_a"}] = index[:untagged]
    end

    test "an operation with multiple tags appears under each" do
      spec = %{
        "paths" => %{"/a" => %{"get" => %{"operationId" => "getA", "tags" => ["x", "y"]}}}
      }

      index = spec |> Operation.extract() |> Operation.tag_index()
      assert [%Operation{id: "get_a"}] = index["x"]
      assert [%Operation{id: "get_a"}] = index["y"]
    end
  end
end
