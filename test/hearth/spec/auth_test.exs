defmodule Hearth.Spec.AuthTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Auth

  defp spec(schemes, security \\ nil) do
    base = %{"components" => %{"securitySchemes" => schemes}}
    if security, do: Map.put(base, "security", security), else: base
  end

  describe "strategy/1" do
    test "no security schemes → :none" do
      assert Auth.strategy(%{}) == :none
      assert Auth.strategy(%{"components" => %{}}) == :none
      assert Auth.strategy(spec(%{})) == :none
    end

    test "HTTP bearer → :bearer" do
      assert Auth.strategy(spec(%{"Token" => %{"type" => "http", "scheme" => "bearer"}})) ==
               :bearer
    end

    test "bearer scheme name is matched case-insensitively" do
      assert Auth.strategy(spec(%{"Token" => %{"type" => "http", "scheme" => "Bearer"}})) ==
               :bearer
    end

    test "apiKey in a header → {:api_key, :header, name}" do
      schemes = %{"Key" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}}
      assert Auth.strategy(spec(schemes)) == {:api_key, :header, "X-API-Key"}
    end

    test "apiKey in a query param → {:api_key, :query, name}" do
      schemes = %{"Key" => %{"type" => "apiKey", "in" => "query", "name" => "api_key"}}
      assert Auth.strategy(spec(schemes)) == {:api_key, :query, "api_key"}
    end

    test "oauth2 → {:unsupported, _}" do
      assert {:unsupported, "oauth2"} =
               Auth.strategy(spec(%{"OAuth" => %{"type" => "oauth2", "flows" => %{}}}))
    end

    test "http basic → {:unsupported, _}" do
      assert {:unsupported, "http/basic"} =
               Auth.strategy(spec(%{"Basic" => %{"type" => "http", "scheme" => "basic"}}))
    end

    test "the top-level `security` requirement picks the primary scheme" do
      schemes = %{
        "OAuth" => %{"type" => "oauth2", "flows" => %{}},
        "Token" => %{"type" => "http", "scheme" => "bearer"}
      }

      # `security` names Token → bearer, even though OAuth sorts first.
      assert Auth.strategy(spec(schemes, [%{"Token" => []}])) == :bearer
    end

    test "without `security`, the first scheme by name order is primary" do
      schemes = %{
        "Zebra" => %{"type" => "http", "scheme" => "bearer"},
        "Apple" => %{"type" => "apiKey", "in" => "header", "name" => "X-Key"}
      }

      # "Apple" sorts before "Zebra".
      assert Auth.strategy(spec(schemes)) == {:api_key, :header, "X-Key"}
    end
  end

  describe "choosing a scheme" do
    @stripe_like %{
      "security" => [%{"basicAuth" => []}, %{"bearerAuth" => []}],
      "components" => %{
        "securitySchemes" => %{
          "basicAuth" => %{"type" => "http", "scheme" => "basic"},
          "bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
          "apiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-Key"}
        }
      }
    }

    test "schemes/1 lists them in the spec's security order, then the rest by name" do
      assert Auth.schemes(@stripe_like) == [
               {"basicAuth", {:unsupported, "http/basic"}},
               {"bearerAuth", :bearer},
               {"apiKey", {:api_key, :header, "X-Key"}}
             ]

      assert Auth.schemes(%{}) == []
    end

    test "default/1 is the first scheme Hearth can wire" do
      assert Auth.default(@stripe_like) == "bearerAuth"
      assert Auth.default(%{}) == nil

      only_basic = %{
        "components" => %{"securitySchemes" => %{"b" => %{"type" => "http", "scheme" => "basic"}}}
      }

      assert Auth.default(only_basic) == "b"
    end

    test "select/2 makes a scheme the one Layer 1 wires" do
      assert {:ok, spec} = Auth.select(@stripe_like, "apiKey")
      assert spec["security"] == [%{"apiKey" => []}]
      assert Auth.strategy(spec) == {:api_key, :header, "X-Key"}
      assert Auth.primary(spec) == "apiKey"

      assert Auth.select(@stripe_like, "oauth") == {:error, ["basicAuth", "bearerAuth", "apiKey"]}
    end

    test "describe/2 is the .hearth.exs record" do
      assert Auth.describe(@stripe_like, "bearerAuth") == [
               scheme: "bearerAuth",
               available: [
                 basicAuth: "http/basic (not supported)",
                 bearerAuth: "bearer",
                 apiKey: "API key in header X-Key"
               ]
             ]

      assert Auth.describe(%{}, nil) == []
    end
  end
end
