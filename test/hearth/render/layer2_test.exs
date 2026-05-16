defmodule Hearth.Render.Layer2Test do
  use ExUnit.Case, async: true

  alias Hearth.Render.Layer2
  alias Hearth.Spec.Operation

  defp op(attrs) do
    struct(Operation, Keyword.merge([path_params: [], tags: [], summary: nil], attrs))
  end

  describe "render/3" do
    test "renders a defmodule with a moduledoc naming the integration" do
      source = Layer2.render(MyApp.Integrations.Petstore.PetstoreApi, [])

      assert source =~ "defmodule MyApp.Integrations.Petstore.PetstoreApi do"
      assert source =~ "@moduledoc"
      assert source =~ "Petstore HTTP integration"
    end

    test "the moduledoc closes with a metadata footer of source and spec info" do
      source =
        Layer2.render(MyApp.Api, [], %{
          source: "priv/specs/ted-api.yaml",
          title: "Public API Documentation",
          version: "3.0.0",
          openapi: "3.1.0"
        })

      assert source =~ "## Source"
      assert source =~ ~s(* **Source:** `priv/specs/ted-api.yaml`)
      assert source =~ "* **Title:** Public API Documentation"
      assert source =~ "* **Version:** 3.0.0"
      assert source =~ "* **OpenAPI:** 3.1.0"
    end

    test "the spec description is included in the metadata footer when present" do
      source =
        Layer2.render(MyApp.Api, [], %{
          source: "spec.json",
          description: "An API for managing things."
        })

      assert source =~ "An API for managing things."
    end

    test "with no metadata the moduledoc carries no Source section" do
      source = Layer2.render(MyApp.Api, [])

      refute source =~ "## Source"
    end

    test "absent metadata fields are skipped, not rendered blank" do
      source = Layer2.render(MyApp.Api, [], %{source: "spec.json", title: "Only Title"})

      assert source =~ "* **Title:** Only Title"
      refute source =~ "**Version:**"
      refute source =~ "**OpenAPI:**"
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

    test "the operation summary becomes a @doc heredoc on the callback" do
      source = Layer2.render(MyApp.Api, [op(id: "list_pets", summary: "List all pets")])

      assert source =~ ~s(@doc """)
      assert source =~ "List all pets"
    end

    test "the description is rendered below the summary" do
      source =
        Layer2.render(MyApp.Api, [
          op(
            id: "list_pets",
            summary: "List all pets",
            description: "Returns every pet currently in the store."
          )
        ])

      assert source =~ "List all pets"
      assert source =~ "Returns every pet currently in the store."

      {summary_at, _} = :binary.match(source, "List all pets")
      {desc_at, _} = :binary.match(source, "Returns every pet")
      assert summary_at < desc_at
    end

    test "an operation with only a description still gets a @doc" do
      source = Layer2.render(MyApp.Api, [op(id: "y", description: "Just a description.")])

      assert source =~ ~s(@doc """)
      assert source =~ "Just a description."
    end

    test "an operation with no summary or description gets no @doc" do
      source = Layer2.render(MyApp.Api, [op(id: "ping")])

      refute source =~ "@doc"
    end

    test "quotes in a summary are kept verbatim — a heredoc needs no escaping" do
      source = Layer2.render(MyApp.Api, [op(id: "x", summary: ~s(echo "hi" back))])

      assert source =~ ~s(echo "hi" back)
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
