defmodule Hearth.Spec.ServersTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Servers

  defp spec(urls), do: %{"servers" => Enum.map(urls, &%{"url" => &1})}

  describe "non_prod?/1" do
    test "a dev/staging/preview/demo/sandbox marker is non-prod" do
      assert Servers.non_prod?("https://dev.acme.com")
      assert Servers.non_prod?("https://api-staging.acme.com")
      assert Servers.non_prod?("https://preview.acme.com")
      assert Servers.non_prod?("https://demo.acme.com")
      assert Servers.non_prod?("https://sandbox.acme.com/v1")
    end

    test "a .dev TLD is non-prod" do
      assert Servers.non_prod?("https://acme.dev")
      assert Servers.non_prod?("https://api.acme.dev/v1")
    end

    test "a plain production URL is not non-prod" do
      refute Servers.non_prod?("https://api.acme.com")
      refute Servers.non_prod?("https://acme.com/v3")
    end
  end

  describe "resolve/1 — default URL" do
    test "no servers → nil default and a warning" do
      assert %{default: nil, test: nil, warn?: true} = Servers.resolve(%{})
    end

    test "one server is both the default and the test URL" do
      r = Servers.resolve(spec(["https://api.acme.com"]))
      assert r.default == "https://api.acme.com"
      assert r.test == "https://api.acme.com"
      refute r.warn?
    end

    test "with one prod-candidate among many, it is the default" do
      r = Servers.resolve(spec(["https://staging.acme.com", "https://api.acme.com"]))
      assert r.default == "https://api.acme.com"
      assert r.default_alternates == []
    end

    test "with many prod-candidates, the first is default and all are documented" do
      urls = ["https://api.acme.com", "https://eu.acme.com", "https://staging.acme.com"]
      r = Servers.resolve(spec(urls))
      assert r.default == "https://api.acme.com"
      assert r.default_alternates == ["https://api.acme.com", "https://eu.acme.com"]
    end

    test "all servers non-prod → the first is the fallback default" do
      r = Servers.resolve(spec(["https://dev.acme.com", "https://staging.acme.com"]))
      assert r.default == "https://dev.acme.com"
      assert r.fallback_default?
    end
  end

  describe "resolve/1 — test URL" do
    test "the single non-prod server is the test URL" do
      r = Servers.resolve(spec(["https://api.acme.com", "https://staging.acme.com"]))
      assert r.test == "https://staging.acme.com"
      assert r.test_alternates == []
    end

    test "with many non-prod servers, the first is the test URL and all are documented" do
      urls = ["https://api.acme.com", "https://staging.acme.com", "https://dev.acme.com"]
      r = Servers.resolve(spec(urls))
      assert r.test == "https://staging.acme.com"
      assert r.test_alternates == ["https://staging.acme.com", "https://dev.acme.com"]
    end

    test "with no non-prod server, the first server is used for the test URL" do
      r = Servers.resolve(spec(["https://api.acme.com", "https://eu.acme.com"]))
      assert r.test == "https://api.acme.com"
    end
  end
end
