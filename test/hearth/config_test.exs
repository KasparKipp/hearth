defmodule Hearth.ConfigTest do
  use ExUnit.Case, async: true

  alias Hearth.Config

  describe "parse/1" do
    test "returns the integrations in file order" do
      content = """
      # a comment
      [
        integrations: [
          stripe: [module: MyApp.Integrations.Stripe, source: "priv/specs/stripe.yaml", base_path: "/v1"],
          send_grid: [module: MyApp.Mail.SendGrid]
        ]
      ]
      """

      assert {:ok, [stripe: stripe, send_grid: send_grid]} = Config.parse(content)
      assert stripe[:module] == MyApp.Integrations.Stripe
      assert stripe[:source] == "priv/specs/stripe.yaml"
      assert stripe[:base_path] == "/v1"
      assert send_grid[:module] == MyApp.Mail.SendGrid
    end

    test "the template has no integrations" do
      assert Config.parse(Config.template()) == {:ok, []}
    end

    test "an empty file has no integrations" do
      assert Config.parse("") == {:ok, []}
      assert Config.parse("[]") == {:ok, []}
    end

    test "a file that doesn't evaluate is an error naming the file" do
      assert {:error, message} = Config.parse("[integrations: [")
      assert message =~ ".hearth.exs"
    end

    test "a file that raises when evaluated is an error naming the file" do
      assert {:error, message} = Config.parse(~s|raise "boom"|)
      assert message =~ ".hearth.exs"
      assert message =~ "boom"
    end

    test "a file that isn't a keyword list is an error" do
      assert {:error, message} = Config.parse(~s|"stripe"|)
      assert message =~ ".hearth.exs"
      assert message =~ "keyword list"
    end

    test "integrations must be a keyword list of keyword lists" do
      assert {:error, message} = Config.parse("[integrations: [stripe: :oops]]")
      assert message =~ "integrations:"

      assert {:error, _} = Config.parse("[integrations: :oops]")
    end
  end

  describe "load/1" do
    test "returns the integrations and the local registry" do
      content = """
      [
        registry: %{
          "ACME_api" => %{
            "1.2" => "https://example.com/1.2/openapi.json",
            "1.3" => "priv/specs/acme-1.3.json",
            "latest" => {:alias, "1.3"}
          }
        },
        integrations: [acme: [module: MyApp.Integrations.Acme, source: "acme_api@1.2"]]
      ]
      """

      assert {:ok, %{integrations: [acme: _], registry: registry}} = Config.load(content)

      assert registry == %{
               "acme_api" => %{
                 "1.2" => "https://example.com/1.2/openapi.json",
                 "1.3" => "priv/specs/acme-1.3.json",
                 "latest" => {:alias, "1.3"}
               }
             }
    end

    test "no registry: is an empty one" do
      assert {:ok, %{registry: %{}}} = Config.load("[integrations: []]")
    end

    test "rejects a malformed registry" do
      for registry <- [
            ~s|[acme: "x"]|,
            ~s|%{"acme" => "https://x"}|,
            ~s|%{"acme" => %{"1" => :url}}|,
            ~s|%{"acme" => %{"1" => {:alias, :two}}}|,
            ~s|%{"bad name!" => %{"1" => "x.json"}}|
          ] do
        assert {:error, message} = Config.load("[registry: #{registry}]")
        assert message =~ "registry:"
      end
    end
  end

  describe "key/1" do
    test "is the snake_case integration name as an atom" do
      assert Config.key("Stripe") == :stripe
      assert Config.key("stripe") == :stripe
      assert Config.key("SendGrid") == :send_grid
      assert Config.key("send_grid") == :send_grid
    end
  end

  describe "module/1" do
    test "returns the entry's module alias" do
      assert Config.module(module: MyApp.Integrations.Stripe) == {:ok, MyApp.Integrations.Stripe}
    end

    test "rejects anything that isn't a module alias" do
      assert Config.module(module: "MyApp.Integrations.Stripe") ==
               {:error, "MyApp.Integrations.Stripe"}

      assert Config.module(module: :stripe) == {:error, :stripe}
      assert Config.module([]) == {:error, nil}
    end
  end

  describe "source/1 and base_path/1" do
    test "return the string, or nil when absent or not a string" do
      entry = [source: "priv/specs/stripe.yaml", base_path: "/v1"]

      assert Config.source(entry) == "priv/specs/stripe.yaml"
      assert Config.base_path(entry) == "/v1"
      assert Config.source([]) == nil
      assert Config.base_path(base_path: :v1) == nil
    end

    test "sources: is the source when present; the label reads it" do
      sources = [items: "priv/specs/items.json", orders: "orders@1.2"]

      assert Config.source(sources: sources) == sources
      assert Config.source_label(sources) == "items: priv/specs/items.json, orders: orders@1.2"
      assert Config.source_label("priv/specs/stripe.yaml") == "priv/specs/stripe.yaml"
    end
  end

  describe "parse/1 with sources:" do
    test "accepts a keyword list of name → source" do
      assert {:ok, [kit: _]} =
               Config.parse(~s|[integrations: [kit: [sources: [a: "a.json", b: "b@1"]]]]|)
    end

    test "rejects anything else, naming the integration" do
      for sources <- [~s|["a.json"]|, ~s|[a: :b]|, ~s|[]|, ~s|"a.json"|] do
        assert {:error, message} =
                 Config.parse("[integrations: [kit: [sources: #{sources}]]]")

        assert message =~ "`sources:` for kit"
      end
    end
  end
end
