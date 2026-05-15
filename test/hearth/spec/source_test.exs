defmodule Hearth.Spec.SourceTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Source

  describe "URL detection" do
    test "https URL" do
      assert Source.resolve("https://example.com/openapi.json") ==
               {:url, "https://example.com/openapi.json"}
    end

    test "http URL" do
      assert Source.resolve("http://example.com/openapi.yaml") ==
               {:url, "http://example.com/openapi.yaml"}
    end

    test "stripe's canonical raw URL" do
      url =
        "https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/latest/openapi.spec3.json"

      assert Source.resolve(url) == {:url, url}
    end
  end

  describe "file detection" do
    test "explicit relative path" do
      assert Source.resolve("./local.yaml") == {:file, "./local.yaml"}
    end

    test "parent-relative path" do
      assert Source.resolve("../specs/stripe.json") == {:file, "../specs/stripe.json"}
    end

    test "absolute path" do
      assert Source.resolve("/tmp/openapi.yaml") == {:file, "/tmp/openapi.yaml"}
    end

    test "subdirectory path" do
      assert Source.resolve("priv/specs/stripe.yaml") == {:file, "priv/specs/stripe.yaml"}
    end

    test "bare filename with .yaml extension" do
      assert Source.resolve("stripe.yaml") == {:file, "stripe.yaml"}
    end

    test "bare filename with .yml extension" do
      assert Source.resolve("api.yml") == {:file, "api.yml"}
    end

    test "bare filename with .json extension" do
      assert Source.resolve("openapi.json") == {:file, "openapi.json"}
    end
  end

  describe "registry detection" do
    test "single lowercase word" do
      assert Source.resolve("stripe") == {:registry, "stripe"}
    end

    test "hyphenated name" do
      assert Source.resolve("petstore-mini") == {:registry, "petstore-mini"}
    end

    test "underscored name" do
      assert Source.resolve("stripe_v2") == {:registry, "stripe_v2"}
    end

    test "case is normalized to lowercase" do
      assert Source.resolve("Stripe") == {:registry, "stripe"}
      assert Source.resolve("GITHUB") == {:registry, "github"}
    end

    test "name@version syntax is preserved" do
      assert Source.resolve("stripe@latest") == {:registry, "stripe@latest"}
      assert Source.resolve("stripe@2024-01-01") == {:registry, "stripe@2024-01-01"}
    end

    test "dotted version tags are preserved" do
      assert Source.resolve("stripe@v1.2.3") == {:registry, "stripe@v1.2.3"}
    end

    test "case-folding applies to @version segment too" do
      assert Source.resolve("Stripe@LATEST") == {:registry, "stripe@latest"}
    end
  end

  describe "errors" do
    test "empty string" do
      assert {:error, "empty source"} = Source.resolve("")
    end

    test "whitespace only" do
      assert {:error, "empty source"} = Source.resolve("   ")
    end

    test "trims surrounding whitespace before classifying" do
      assert Source.resolve("  stripe  ") == {:registry, "stripe"}
    end

    test "input with internal whitespace is unclassifiable" do
      assert {:error, msg} = Source.resolve("foo bar")
      assert msg =~ "could not classify"
    end

    test "input starting with a digit is still a valid registry name" do
      assert Source.resolve("3legged") == {:registry, "3legged"}
    end

    test "input with leading dash is unclassifiable" do
      assert {:error, msg} = Source.resolve("-stripe")
      assert msg =~ "could not classify"
    end
  end
end
