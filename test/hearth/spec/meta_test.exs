defmodule Hearth.Spec.MetaTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Meta

  describe "put/2 + readers" do
    test "round-trips the base path and source" do
      spec = Meta.put(%{"openapi" => "3.0.0"}, base_path: "/v1", source: "priv/specs/x.yaml")

      assert Meta.base_path(spec) == "/v1"
      assert Meta.source(spec) == "priv/specs/x.yaml"
    end

    test "stores the block under the x-hearth extension key" do
      spec = Meta.put(%{}, base_path: "", source: "s.yaml")
      assert spec["x-hearth"] == %{"base_path" => "", "source" => "s.yaml"}
    end
  end

  describe "readers on a spec without metadata" do
    test "return nil when the block is absent" do
      assert Meta.base_path(%{}) == nil
      assert Meta.source(%{}) == nil
    end

    test "return nil when the block is malformed" do
      spec = %{"x-hearth" => %{"base_path" => 1, "source" => ["x"]}}
      assert Meta.base_path(spec) == nil
      assert Meta.source(spec) == nil

      assert Meta.base_path(%{"x-hearth" => "nope"}) == nil
    end
  end
end
