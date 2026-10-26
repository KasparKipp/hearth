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

      assert source =~ "previous = Application.get_env(:my_app, @client, [])"
      assert source =~ "configure_api_key(@api_key)"
      assert source =~ "on_exit(fn -> Application.put_env(:my_app, @client, previous) end)"

      assert source =~
               "Application.put_env(:my_app, @client, Keyword.put(config, :api_key, value))"

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

    # The keyed tests double as examples of every way to supply the
    # credential: config (string, fun, MFA), per call (string, fun),
    # new/1, and a credential set explicitly on the request.
    for auth <- [:bearer, {:api_key, :header, "X-API-Key"}, {:api_key, :query, "api_key"}] do
      test "#{inspect(auth)} shows every way to supply the credential" do
        source = render(unquote(Macro.escape(auth)))

        for name <- [
              "config api_key: may be a 0-arity function, resolved per request",
              "config api_key: may be an {m, f, a} tuple",
              "a per-call api_key: overrides config",
              "a per-call api_key: may be a function",
              "new/1 accepts api_key: too",
              "a credential set explicitly on the request wins"
            ] do
          assert source =~ ~s(test "#{name}" do)
        end

        assert source =~ ~s|configure_api_key(fn -> "from-function" end)|
        assert source =~ "configure_api_key({__MODULE__, :fetch_api_key, []})"
        assert source =~ ~s|def fetch_api_key, do: "from-mfa"|
        assert source =~ ~s|api_key: "per-call"|
        assert source =~ ~s|api_key: fn -> "per-call-function" end|

        assert source =~
                 ~s|Req.request!(@client.new(url: "/ping", api_key: "from-new", plug: plug))|
      end
    end

    test "each keyed scheme's explicit credential is set the scheme's own way" do
      assert render(:bearer) =~ ~s|auth: {:bearer, "explicit-credential"}|

      assert render({:api_key, :header, "X-API-Key"}) =~
               ~s|headers: [{"x-api-key", "explicit-credential"}]|

      assert render({:api_key, :query, "api_key"}) =~
               ~s|params: %{"api_key" => "explicit-credential"}|
    end

    test "query auth shows the key travelling alongside the caller's params:" do
      source = render({:api_key, :query, "api_key"})

      assert source =~ ~s(test "the key travels alongside the caller's params:" do)
      assert source =~ "params: [limit: 5]"
      assert source =~ ~s|conn.query_params == %{"api_key" => @api_key, "limit" => "5"}|
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

  describe "layer1/5 with headers:" do
    @headers [{"x-app-key", :app_key}, {"x-tenant-id", :tenant_id}]

    defp render_headers(auth),
      do: Tests.layer1(@test_module, @client, :my_app, auth, headers: @headers)

    test "seeds each header's config key in setup" do
      source = render_headers(:none)

      assert source =~ "Keyword.merge(previous,"
      assert source =~ ~s/app_key: "hearth-test-app_key"/
      assert source =~ ~s/tenant_id: "hearth-test-tenant_id"/

      assert source =~ "on_exit(fn -> Application.put_env(:my_app, @client, previous) end)"
    end

    test "checks each header from config, per call, and set by the caller" do
      source = render_headers(:none)

      for {name, key} <- @headers do
        assert source =~ ~s(test "request! sets the #{name} header from config" do)

        assert source =~
                 ~s|assert Plug.Conn.get_req_header(conn, "#{name}") == ["hearth-test-#{key}"]|

        assert source =~ ~s(test "a per-call #{key}: overrides config" do)
        assert source =~ ~s(#{key}: "per-call")
        assert source =~ ~s(test "an explicit #{name} header wins" do)
        assert source =~ ~s(headers: [{"#{name}", "explicit-credential"}])
      end
    end

    test "keeps the credential setup and tests alongside" do
      source = render_headers(:bearer)

      assert source =~ "configure_api_key(@api_key)"
      assert source =~ ~s(test "request! attaches a bearer token from config" do)
      assert source =~ ~s(test "request! sets the x-tenant-id header from config" do)
    end

    test "renders nothing extra without headers" do
      assert Tests.layer1(@test_module, @client, :my_app, :none, headers: []) == render(:none)
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
      assert source =~ "previous = Application.get_env(:my_app, @client, [])"
      assert source =~ "Keyword.put(previous, :api_key, api_key)"
      assert source =~ "on_exit(fn -> Application.put_env(:my_app, @client, previous) end)"
    end

    test ":none auth needs no credential — async: true, no setup" do
      source = render_external(:none)

      assert source =~ "use ExUnit.Case, async: true"
      refute source =~ "setup do"
      refute source =~ "Application.put_env"
    end

    test "headers read their values from env vars, next to the credential" do
      source =
        Tests.external(
          @external_module,
          @layer2,
          @client,
          :my_app,
          :bearer,
          [op(id: "list_pets")],
          headers: [{"x-tenant-id", :tenant_id}]
        )

      assert source =~ "use ExUnit.Case, async: false"
      assert source =~ ~s/api_key: System.get_env("STRIPE_API_KEY") || "DEV_NO_STRIPE_API_KEY"/

      assert source =~
               ~s/tenant_id: System.get_env("STRIPE_TENANT_ID") || "DEV_NO_STRIPE_TENANT_ID"/

      assert source =~ "Application.put_env(:my_app, @client, config)"
    end

    test "headers alone make the external test async: false" do
      source =
        Tests.external(@external_module, @layer2, @client, :my_app, :none, [op(id: "list_pets")],
          headers: [{"x-tenant-id", :tenant_id}]
        )

      assert source =~ "use ExUnit.Case, async: false"
      refute source =~ "api_key"
    end

    test "every rendered external file is syntactically valid Elixir" do
      for auth <- [:none, :bearer, {:api_key, :header, "X-Key"}, {:unsupported, "oauth2"}] do
        assert {:defmodule, _meta, _body} = Code.string_to_quoted!(render_external(auth))
      end
    end
  end
end
