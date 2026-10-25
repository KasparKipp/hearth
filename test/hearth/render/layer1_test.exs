defmodule Hearth.Render.Layer1Test do
  use ExUnit.Case, async: true

  alias Hearth.Render.Layer1

  describe "render/5" do
    test "renders a defmodule with the base URL and otp_app" do
      source =
        Layer1.render(MyApp.Integrations.Stripe, :my_app, "https://api.stripe.com", "", :none)

      assert source =~ "defmodule MyApp.Integrations.Stripe do"
      assert source =~ ~s(@otp_app :my_app)
      assert source =~ ~s(@base_url "https://api.stripe.com")
      assert source =~ "Raw Req client for the Stripe integration"
    end

    # Behaviour is covered by Layer1RuntimeTest; these pin the shape.
    test ":bearer auth registers :api_key and attaches it in a request step" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "", :bearer)

      assert source =~ "|> Req.Request.register_options([:api_key])"
      assert source =~ "|> Req.Request.append_request_steps(put_api_key: &put_api_key/1)"
      assert source =~ ~s|"Bearer " <> credential(request)|
      assert source =~ "defp credential(request) do"

      assert source =~
               "request.options[:api_key] || Application.get_env(@otp_app, __MODULE__, [])[:api_key]"

      assert source =~ "## Credentials"
    end

    test "API-key header auth sets the header from the credential" do
      source =
        Layer1.render(MyApp.Api, :my_app, "https://x", "", {:api_key, :header, "X-API-Key"})

      assert source =~ ~s|Req.Request.put_header(request, "x-api-key", credential(request))|
      assert source =~ "defp credential(request) do"
    end

    test "API-key query auth sets the query param from the credential" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "", {:api_key, :query, "api_key"})

      assert source =~ ~s|URI.encode_query([{"api_key", credential(request)}])|
      refute source =~ "params:"
    end

    test ":none auth produces a base-URL-only client and no credential reader" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "", :none)

      assert source =~ "Req.new(base_url: base_url()) |> Req.merge(opts)"
      refute source =~ "defp credential"
      refute source =~ "## Credentials"
      assert source =~ "def new(opts \\\\ []) do"
    end

    test "unsupported auth leaves a TODO and a base-URL-only client" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "", {:unsupported, "oauth2"})

      assert source =~ "# TODO:"
      assert source =~ ~s("oauth2")
      assert source =~ "Req.new(base_url: base_url()) |> Req.merge(opts)"
      refute source =~ "defp credential"
    end

    test "request/2 and request!/2 dispatch through new/1, for every auth" do
      for auth <- [:none, :bearer, {:api_key, :header, "X-Key"}, {:unsupported, "oauth2"}] do
        source = Layer1.render(MyApp.Api, :my_app, "https://x", "", auth)

        assert source =~ "def request(url, opts \\\\ []), do: Req.request(new(url: url), opts)"
        assert source =~ "def request!(url, opts \\\\ []), do: Req.request!(new(url: url), opts)"
      end
    end

    test "the base URL is config-overridable, falling back to @base_url" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "", :bearer)

      assert source =~ "Req.new(base_url: base_url()"

      assert source =~
               "defp base_url, do: Application.get_env(@otp_app, __MODULE__, [])[:base_url] || @base_url"
    end

    test "a nil base URL leaves a TODO and a placeholder" do
      source = Layer1.render(MyApp.Api, :my_app, nil, "", :none)

      assert source =~ "# TODO: the spec declared no `servers`"
      assert source =~ ~s(@base_url "https://api.example.com")
    end

    test "a shared path prefix is appended to the base URL" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x", "/v3", :none)
      assert source =~ ~s(@base_url "https://x/v3")
    end

    test "a shared path prefix is folded into the nil-base-URL placeholder too" do
      source = Layer1.render(MyApp.Api, :my_app, nil, "/v3", :none)

      assert source =~ "# TODO: the spec declared no `servers`"
      assert source =~ ~s(@base_url "https://api.example.com/v3")
    end

    test "a trailing slash on the base URL is not doubled when a prefix is appended" do
      source = Layer1.render(MyApp.Api, :my_app, "https://x/", "/v3", :none)
      assert source =~ ~s(@base_url "https://x/v3")
    end

    test "the rendered module is syntactically valid Elixir" do
      for auth <- [:none, :bearer, {:api_key, :header, "X-Key"}, {:unsupported, "oauth2"}] do
        source = Layer1.render(MyApp.Api, :my_app, "https://x", "", auth)
        assert {:defmodule, _meta, _body} = Code.string_to_quoted!(source)
      end
    end
  end
end
