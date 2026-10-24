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
end
