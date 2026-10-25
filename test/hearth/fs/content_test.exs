defmodule Hearth.Fs.ContentTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Hearth.Fs.Content

  describe "read/2" do
    test "returns the content of a file in the igniter's Rewrite" do
      igniter = test_project(files: %{"priv/spec.yaml" => "openapi: 3.0.0\n"})

      assert Content.read(igniter, "priv/spec.yaml") == {:ok, "openapi: 3.0.0\n"}
    end

    test "returns an error tuple for a file not in the Rewrite" do
      igniter = test_project()

      assert {:error, %Rewrite.Error{}} = Content.read(igniter, "priv/missing.yaml")
    end
  end

  describe "read_spec/2" do
    test "decodes a YAML or JSON spec file" do
      igniter =
        test_project(
          files: %{"priv/a.yaml" => "openapi: 3.0.0\n", "priv/b.json" => ~s|{"openapi": "3.1.0"}|}
        )

      assert {:ok, %Igniter{}, %{"openapi" => "3.0.0"}} =
               Content.read_spec(igniter, "priv/a.yaml")

      assert {:ok, _igniter, %{"openapi" => "3.1.0"}} = Content.read_spec(igniter, "priv/b.json")
    end

    test "names why it couldn't" do
      igniter = test_project(files: %{"priv/bad.json" => "{", "priv/spec.txt" => ""})

      assert Content.read_spec(igniter, "priv/spec.txt") == {:error, :unsupported}
      assert Content.read_spec(igniter, "priv/missing.yaml") == {:error, :missing}
      assert {:error, {:decode, _reason}} = Content.read_spec(igniter, "priv/bad.json")
    end
  end
end
