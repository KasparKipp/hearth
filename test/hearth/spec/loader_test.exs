defmodule Hearth.Spec.LoaderTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Loader

  describe "sniff/1" do
    test ".yaml extension" do
      assert Loader.sniff("priv/specs/foo.yaml") == :yaml
    end

    test ".yml extension" do
      assert Loader.sniff("priv/specs/foo.yml") == :yaml
    end

    test ".json extension" do
      assert Loader.sniff("priv/specs/foo.json") == :json
    end

    test "case-insensitive on the extension" do
      assert Loader.sniff("FOO.YAML") == :yaml
      assert Loader.sniff("FOO.JSON") == :json
    end

    test "URL with query string still classifies by extension" do
      assert Loader.sniff("https://example.com/spec.yaml?ref=main") == :yaml
      assert Loader.sniff("https://example.com/spec.json?ref=main") == :json
    end

    test "unknown extensions return :unknown" do
      assert Loader.sniff("priv/specs/foo.xml") == :unknown
      assert Loader.sniff("priv/specs/foo") == :unknown
      assert Loader.sniff("") == :unknown
    end
  end

  describe "decode/2 — YAML" do
    test "decodes a minimal map" do
      yaml = """
      openapi: 3.0.0
      info:
        title: Test
        version: 1.0.0
      """

      assert {:ok, %{"openapi" => "3.0.0", "info" => info}} = Loader.decode(yaml, :yaml)
      assert info == %{"title" => "Test", "version" => "1.0.0"}
    end

    test "returns an error tuple for malformed YAML, without raising" do
      assert {:error, _reason} = Loader.decode("[unclosed: yaml", :yaml)
    end

    test "loads the OAI 3.0 petstore (YAML)" do
      bytes = File.read!("test/fixtures/specs/petstore-3.0.yaml")
      assert {:ok, spec} = Loader.decode(bytes, :yaml)

      assert spec["openapi"] == "3.0.0"
      assert get_in(spec, ["info", "title"]) == "Swagger Petstore"
      assert is_map(spec["paths"])
      assert map_size(spec["paths"]) >= 2
      # Golden fixture exercises components/schemas, which our hand-rolled
      # tiny fixture didn't.
      assert get_in(spec, ["components", "schemas", "Pet"]) |> is_map()
    end

    test "loads the OAI 3.1 tictactoe (YAML)" do
      bytes = File.read!("test/fixtures/specs/tictactoe-3.1.yaml")
      assert {:ok, spec} = Loader.decode(bytes, :yaml)

      assert spec["openapi"] == "3.1.0"
      assert get_in(spec, ["info", "title"]) == "Tic Tac Toe"
    end
  end

  describe "decode/2 — JSON" do
    test "decodes a minimal map" do
      json = ~s({"openapi": "3.0.0", "info": {"title": "Test", "version": "1.0.0"}})

      assert {:ok, %{"openapi" => "3.0.0", "info" => info}} = Loader.decode(json, :json)
      assert info == %{"title" => "Test", "version" => "1.0.0"}
    end

    test "returns an error tuple for malformed JSON, without raising" do
      assert {:error, _reason} = Loader.decode("not json", :json)
    end

    test "loads the OAI 3.0 petstore (JSON)" do
      bytes = File.read!("test/fixtures/specs/petstore-3.0.json")
      assert {:ok, spec} = Loader.decode(bytes, :json)

      assert spec["openapi"] == "3.0.0"
      assert get_in(spec, ["info", "title"]) == "Swagger Petstore"
      assert get_in(spec, ["components", "schemas", "Pet"]) |> is_map()
    end

    test "loads the OAI 3.1 tictactoe (JSON)" do
      bytes = File.read!("test/fixtures/specs/tictactoe-3.1.json")
      assert {:ok, spec} = Loader.decode(bytes, :json)

      assert spec["openapi"] == "3.1.0"
      assert get_in(spec, ["info", "title"]) == "Tic Tac Toe"
    end
  end
end
