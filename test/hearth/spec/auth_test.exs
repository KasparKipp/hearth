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
end
