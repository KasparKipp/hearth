defmodule Hearth.Render.Layer2Test do
  use ExUnit.Case, async: true

  alias Hearth.Render.Layer2
  alias Hearth.Spec.Operation

  defp op(attrs) do
    struct(Operation, Keyword.merge([path_params: [], tags: [], summary: nil], attrs))
  end

  describe "render/2" do
    test "renders a defmodule with a moduledoc naming the integration" do
      source = Layer2.render(MyApp.Integrations.Petstore.PetstoreApi, [])

      assert source =~ "defmodule MyApp.Integrations.Petstore.PetstoreApi do"
      assert source =~ "@moduledoc"
      assert source =~ "Petstore HTTP integration"
    end

    test "one @callback per operation with the generic return type" do
      source = Layer2.render(MyApp.Api, [op(id: "list_pets"), op(id: "create_pet")])

      assert source =~
               "@callback list_pets(opts :: keyword()) :: " <>
                 "{:ok, Req.Response.t()} | {:error, Exception.t()}"

      assert source =~ "@callback create_pet(opts :: keyword()) ::"
    end

    test "a path param becomes a positional String.t() arg before opts" do
      ops = [op(id: "show_pet", path_params: [%{"name" => "petId", "in" => "path"}])]
      source = Layer2.render(MyApp.Api, ops)

      assert source =~ "@callback show_pet(pet_id :: String.t(), opts :: keyword()) ::"
    end

    test "multiple path params keep spec order" do
      ops = [
        op(
          id: "get_square",
          path_params: [
            %{"name" => "row", "in" => "path"},
            %{"name" => "column", "in" => "path"}
          ]
        )
      ]

      source = Layer2.render(MyApp.Api, ops)

      assert source =~
               "get_square(row :: String.t(), column :: String.t(), opts :: keyword())"
    end

    test "the operation summary becomes a @doc on the callback" do
      source = Layer2.render(MyApp.Api, [op(id: "list_pets", summary: "List all pets")])

      assert source =~ ~s(@doc "List all pets")
    end

    test "an operation with no summary gets no @doc" do
      source = Layer2.render(MyApp.Api, [op(id: "ping")])

      refute source =~ "@doc"
    end

    test "quotes in a summary are escaped" do
      source = Layer2.render(MyApp.Api, [op(id: "x", summary: ~s(echo "hi" back))])

      assert source =~ ~s(@doc "echo \\"hi\\" back")
    end

    test "the rendered module is syntactically valid Elixir" do
      ops = [
        op(id: "list_pets", summary: "List"),
        op(id: "show_pet", path_params: [%{"name" => "id", "in" => "path"}])
      ]

      source = Layer2.render(MyApp.Api, ops)
      assert {:defmodule, _meta, _body} = Code.string_to_quoted!(source)
    end
  end
end
