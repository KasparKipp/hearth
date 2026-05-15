defmodule Hearth.Render.Layer1Test do
  use ExUnit.Case, async: true

  alias Hearth.Render.Layer1

  describe "render/4" do
    test "renders a defmodule with the base URL and otp_app" do
      source = Layer1.render(MyApp.Integrations.Stripe, :my_app, "https://api.stripe.com", :none)

      assert source =~ "defmodule MyApp.Integrations.Stripe do"
      assert source =~ ~s(@otp_app :my_app)
      assert source =~ ~s(@base_url "https://api.stripe.com")
      assert source =~ "Raw Req client for the Stripe integration"
    end

    test ":bearer auth attaches a bearer token and a credential/1 reader" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", :bearer)

      assert source =~ "auth: {:bearer, credential(opts)}"
      assert source =~ "defp credential(opts) do"
      assert source =~ "Application.get_env(@otp_app, __MODULE__, [])[:api_key]"
      assert source =~ "opts[:api_key]"
    end

    test "API-key header auth sets the header from the credential" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", {:api_key, :header, "X-API-Key"})

      assert source =~ ~s|headers: [{"X-API-Key", credential(opts)}]|
      assert source =~ "defp credential(opts) do"
    end

    test "API-key query auth sets the query param from the credential" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", {:api_key, :query, "api_key"})

      assert source =~ ~s|params: %{"api_key" => credential(opts)}|
    end

    test ":none auth produces a base-URL-only client and no credential reader" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", :none)

      assert source =~ "Req.new(base_url: @base_url)"
      refute source =~ "defp credential"
      assert source =~ "def client(_opts"
    end

    test "unsupported auth leaves a TODO and a base-URL-only client" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", {:unsupported, "oauth2"})

      assert source =~ "# TODO:"
      assert source =~ ~s("oauth2")
      assert source =~ "Req.new(base_url: @base_url)"
      refute source =~ "defp credential"
    end

    test "a nil base URL leaves a TODO and a placeholder" do
      source = Layer1.render(MyApp.Api, :my_app, nil, :none)

      assert source =~ "# TODO: the spec declared no `servers`"
      assert source =~ ~s(@base_url "https://api.example.com")
    end

    test "the rendered module is syntactically valid Elixir" do
      for auth <- [:none, :bearer, {:api_key, :header, "X-Key"}, {:unsupported, "oauth2"}] do
        source = Layer1.render(MyApp.Api, :my_app, "https://x", auth)
        assert {:defmodule, _meta, _body} = Code.string_to_quoted!(source)
      end
    end
  end
end
