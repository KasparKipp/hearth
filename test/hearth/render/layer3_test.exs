defmodule Hearth.Render.Layer3Test do
  use ExUnit.Case, async: true

  alias Hearth.Render.Layer3
  alias Hearth.Spec.Operation

  defp op(attrs) do
    struct(Operation, Keyword.merge([path_params: [], tags: [], method: :get], attrs))
  end

  @layer3 MyApp.Integrations.Stripe.StripeApi.Req
  @layer2 MyApp.Integrations.Stripe.StripeApi
  @layer1 MyApp.Integrations.Stripe

  defp render(operations), do: Layer3.render(@layer3, @layer2, @layer1, operations)

  describe "render/4" do
    test "declares the behaviour and aliases the Layer 1 client" do
      source = render([])

      assert source =~ "defmodule MyApp.Integrations.Stripe.StripeApi.Req do"
      assert source =~ "@behaviour MyApp.Integrations.Stripe.StripeApi"
      assert source =~ "alias MyApp.Integrations.Stripe"
    end

    test "one @impl function per operation, delegating to the client's request/2" do
      source = render([op(id: "list_pets", path: "/pets", method: :get)])

      assert source =~ "@impl true"
      assert source =~ "def list_pets(opts \\\\ []) do"
      assert source =~ "Stripe.request(\"/pets\", opts)"
    end

    test ":get is Req's default — the method is left unspecified" do
      source = render([op(id: "list_pets", path: "/pets", method: :get)])

      refute source =~ "method: :get"
    end

    test "never touches new/1 or Req directly — only the client's request/2" do
      source = render([op(id: "list_pets", path: "/pets")])

      refute source =~ "defp request"
      refute source =~ ".new("
      refute source =~ "Req.request"
      assert source =~ "Stripe.request("
    end

    test "the HTTP method comes from the operation" do
      source = render([op(id: "create_pet", path: "/pets", method: :post)])
      assert source =~ "Stripe.request(\"/pets\", [method: :post] ++ opts)"
    end

    test "a path param becomes a positional arg interpolated into the URL" do
      source =
        render([
          op(
            id: "show_pet",
            path: "/pets/{petId}",
            method: :get,
            path_params: [%{"name" => "petId", "in" => "path"}]
          )
        ])

      assert source =~ "def show_pet(pet_id, opts \\\\ []) do"

      assert source =~
               "Stripe.request(\"/pets/\#{pet_id}\", opts)"
    end

    test "multiple path params interpolate in spec order" do
      source =
        render([
          op(
            id: "get_square",
            path: "/board/{row}/{column}",
            method: :get,
            path_params: [
              %{"name" => "row", "in" => "path"},
              %{"name" => "column", "in" => "path"}
            ]
          )
        ])

      assert source =~ "def get_square(row, column, opts \\\\ [])"
      assert source =~ "\"/board/\#{row}/\#{column}\""
    end

    test "the rendered module is syntactically valid Elixir" do
      ops = [
        op(id: "list_pets", path: "/pets", method: :get),
        op(
          id: "show_pet",
          path: "/pets/{petId}",
          method: :get,
          path_params: [%{"name" => "petId", "in" => "path"}]
        )
      ]

      assert {:defmodule, _meta, _body} = Code.string_to_quoted!(render(ops))
    end
  end
end
