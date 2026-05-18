defmodule Hearth.Render.TestsTest do
  use ExUnit.Case, async: true

  alias Hearth.Render.Tests
  alias Hearth.Spec.Operation

  @test_module App.Integrations.StripeTest
  @client App.Integrations.Stripe
  @layer2 App.Integrations.Stripe.StripeApi
  @external_module App.Integrations.StripeExternalTest

  defp render(auth), do: Tests.layer1(@test_module, @client, :my_app, auth)

  defp op(attrs), do: struct(Operation, Keyword.merge([path_params: [], tags: []], attrs))

  defp render_external(auth, operations \\ [op(id: "list_pets")]) do
    Tests.external(@external_module, @layer2, @client, :my_app, auth, operations)
  end

  describe "layer1/4" do
    test "renders an async: false ExUnit module for the client" do
      source = render(:none)

      assert source =~ "defmodule App.Integrations.StripeTest do"
      assert source =~ "use ExUnit.Case, async: false"
      assert source =~ "@client App.Integrations.Stripe"
    end

    test "the module is guarded so the file compiles without the plug dep" do
      source = render(:bearer)

      assert source =~ "if Code.ensure_loaded?(Plug.Conn) do"
    end

    test "bearer auth seeds the credential and asserts the bearer header" do
      source = render(:bearer)

      assert source =~ "Application.put_env(:my_app, @client, api_key: @api_key)"
      assert source =~ "on_exit(fn -> Application.delete_env(:my_app, @client) end)"

      assert source =~
               ~s|Plug.Conn.get_req_header(conn, "authorization") == ["Bearer \#{@api_key}"]|

      assert source =~ ~s|@client.request!("/ping", plug: plug)|
    end

    test "API-key header auth asserts the downcased header name" do
      source = render({:api_key, :header, "X-API-Key"})

      assert source =~ "Application.put_env(:my_app, @client"
      assert source =~ ~s|Plug.Conn.get_req_header(conn, "x-api-key") == [@api_key]|
    end

    test "API-key query auth asserts the query param" do
      source = render({:api_key, :query, "api_key"})

      assert source =~ "Plug.Conn.fetch_query_params(conn)"
      assert source =~ ~s|conn.query_params["api_key"] == @api_key|
    end

    test ":none auth asserts no authorization header and seeds no credential" do
      source = render(:none)

      assert source =~ ~s|Plug.Conn.get_req_header(conn, "authorization") == []|
      refute source =~ "Application.put_env"
      refute source =~ "setup do"
    end

    test "unsupported auth renders a smoke test and a TODO, no credential" do
      source = render({:unsupported, "oauth2"})

      assert source =~ "# TODO: oauth2 auth is not auto-wired"
      assert source =~ "auth not wired"
      refute source =~ "Application.put_env"
    end

    test "every rendered file is syntactically valid Elixir, guarded by an if" do
      for auth <- [
            :none,
            :bearer,
            {:api_key, :header, "X-Key"},
            {:api_key, :query, "k"},
            {:unsupported, "oauth2"}
          ] do
        assert {:if, _meta, _body} = Code.string_to_quoted!(render(auth))
      end
    end
  end

  describe "external/6" do
    test "renders an :external-tagged ExUnit module aliasing Layer 2" do
      source = render_external(:none)

      assert source =~ "defmodule App.Integrations.StripeExternalTest do"
      assert source =~ "@moduletag :external"
      assert source =~ "alias App.Integrations.Stripe.StripeApi"
    end

    test "one test per operation, calling Layer 3 (the .Req impl) directly" do
      source =
        render_external(:none, [op(id: "list_pets"), op(id: "create_pet")])

      assert source =~ ~s(test "list_pets reaches the live API" do)
      assert source =~ "assert {:ok, %Req.Response{}} = StripeApi.Req.list_pets([])"
      assert source =~ ~s(test "create_pet reaches the live API" do)
      assert source =~ "StripeApi.Req.create_pet([])"
      assert source =~ "# TODO:"
    end

    test "a path param becomes a placeholder positional arg" do
      source =
        render_external(:none, [
          op(id: "show_pet", path_params: [%{"name" => "petId", "in" => "path"}])
        ])

      assert source =~ ~s/StripeApi.Req.show_pet("TODO", [])/
    end

    test "credentialed auth seeds the key from env and runs async: false" do
      source = render_external(:bearer)

      assert source =~ "use ExUnit.Case, async: false"
      assert source =~ "@client App.Integrations.Stripe"
      assert source =~ ~s/System.get_env("STRIPE_API_KEY")/
      assert source =~ ~s/"DEV_NO_STRIPE_API_KEY"/
      assert source =~ "on_exit(fn -> Application.delete_env(:my_app, @client) end)"
    end

    test ":none auth needs no credential — async: true, no setup" do
      source = render_external(:none)

      assert source =~ "use ExUnit.Case, async: true"
      refute source =~ "setup do"
      refute source =~ "Application.put_env"
    end

    test "every rendered external file is syntactically valid Elixir" do
      for auth <- [:none, :bearer, {:api_key, :header, "X-Key"}, {:unsupported, "oauth2"}] do
        assert {:defmodule, _meta, _body} = Code.string_to_quoted!(render_external(auth))
      end
    end
  end
end
