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

    test "resolves path-item-level $ref path params", %{ops: ops} do
      assert param_names(by_id(ops, "get_square").path_params) == ["row", "column"]
      assert param_names(by_id(ops, "put_square").path_params) == ["row", "column"]
    end
  end

  describe "extract/1 — parameters" do
    defp spec_with(path, path_item, component_params \\ %{}) do
      %{
        "paths" => %{path => path_item},
        "components" => %{"parameters" => component_params}
      }
    end

    test "resolves a $ref to components.parameters" do
      spec =
        spec_with(
          "/items",
          %{"get" => %{"parameters" => [%{"$ref" => "#/components/parameters/limit"}]}},
          %{"limit" => %{"name" => "limit", "in" => "query"}}
        )

      assert [%Operation{query_params: [%{"name" => "limit", "in" => "query"}]}] =
               Operation.extract(spec)
    end

    test "an operation-level param overrides a path-level one with the same name and location" do
      spec =
        spec_with("/items/{id}", %{
          "parameters" => [%{"name" => "id", "in" => "path", "description" => "shared"}],
          "get" => %{
            "parameters" => [%{"name" => "id", "in" => "path", "description" => "override"}]
          }
        })

      assert [%Operation{path_params: [%{"description" => "override"}]}] =
               Operation.extract(spec)
    end

    test "a template segment with no declared param still becomes a path param" do
      spec =
        spec_with("/orgs/{org}/repos/{repo}", %{
          "get" => %{"parameters" => [%{"name" => "org", "in" => "path"}]}
        })

      [op] = Operation.extract(spec)
      assert param_names(op.path_params) == ["org", "repo"]
    end

    test "an unresolvable $ref falls back to the path template" do
      spec =
        spec_with("/users/{user_id}", %{
          "get" => %{"parameters" => [%{"$ref" => "#/components/parameters/missing"}]}
        })

      [op] = Operation.extract(spec)
      assert param_names(op.path_params) == ["user_id"]
    end
  end

  describe "extract/1 — safe function names" do
    defp ids_for(operation_ids) do
      paths =
        operation_ids
        |> Enum.with_index()
        |> Map.new(fn {op_id, i} -> {"/p#{i}", %{"get" => %{"operationId" => op_id}}} end)

      %{"paths" => paths} |> Operation.extract() |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "a reserved word gets a trailing underscore" do
      assert ids_for(["end", "do", "fn", "nil", "when"]) == ~w(do_ end_ fn_ nil_ when_)
    end

    test "a leading digit gets an op_ prefix" do
      assert ids_for(["2fa-verify"]) == ["op_2fa_verify"]
    end

    test "names that clash with generated or built-in functions get a trailing underscore" do
      # `impl/0` is Layer 2's private dispatcher; `module_info` is
      # defined on every module by the compiler.
      assert ids_for(["impl", "moduleInfo"]) == ~w(impl_ module_info_)
    end

    test "an operationId that sanitizes to nothing falls back to <verb>_<path-slug>" do
      spec = %{"paths" => %{"/items" => %{"get" => %{"operationId" => "---"}}}}
      assert [%Operation{id: "get_items"}] = Operation.extract(spec)
    end

    test "numeric dedupe skips a suffix another operation already uses" do
      spec = %{
        "paths" => %{
          "/a" => %{"get" => %{"operationId" => "getUser"}},
          "/b" => %{"get" => %{"operationId" => "getUser"}},
          "/c" => %{"get" => %{"operationId" => "get_user_2"}}
        }
      }

      ops = Operation.extract(spec)
      assert ops |> Enum.map(& &1.id) |> Enum.sort() == ~w(get_user get_user_2 get_user_3)
      assert Enum.find(ops, &(&1.path == "/c")).id == "get_user_2"
    end
  end

  describe "function_name/1" do
    test "matches the id extract/1 derives, so user-supplied ids still match" do
      assert Operation.function_name("getBoard") == "get_board"
      assert Operation.function_name("end") == "end_"
      assert Operation.function_name("2fa") == "op_2fa"
    end
  end

  describe "path_args/1" do
    defp args_for(names) do
      params = Enum.map(names, &%{"name" => &1, "in" => "path"})
      Operation.path_args(struct(Operation, path_params: params))
    end

    test "snake_cases each path param name" do
      assert args_for(["petId", "owner-name"]) == ["pet_id", "owner_name"]
    end

    test "a reserved word or `opts` gets a trailing underscore" do
      assert args_for(["end", "opts"]) == ["end_", "opts_"]
    end

    test "a leading digit gets a param_ prefix" do
      assert args_for(["1id"]) == ["param_1id"]
    end

    test "a missing or empty name becomes `param`" do
      params = [%{"in" => "path"}, %{"name" => "", "in" => "path"}]
      assert Operation.path_args(struct(Operation, path_params: params)) == ["param", "param_2"]
    end

    test "names that collide after sanitizing get numeric suffixes" do
      assert args_for(["petId", "pet_id"]) == ["pet_id", "pet_id_2"]
    end
  end

  defp param_names(params), do: Enum.map(params, & &1["name"])

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
