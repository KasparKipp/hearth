defmodule Hearth.Fs.OwnershipTest do
  use ExUnit.Case, async: true

  alias Hearth.Fs.Ownership

  describe "classify/1" do
    test "a file with no token is :none" do
      assert Ownership.classify("defmodule X do\n  @moduledoc \"raw client\"\nend\n") == :none
    end

    test "a hearth:owned token in a heredoc moduledoc is :owned" do
      content = """
      defmodule X do
        @moduledoc \"\"\"
        Raw client.

        hearth:owned
        \"\"\"
      end
      """

      assert Ownership.classify(content) == :owned
    end

    test "a hearth:collaborating token in a string moduledoc is :collaborating" do
      content = "defmodule X do\n  @moduledoc \"hearth:collaborating\"\nend\n"
      assert Ownership.classify(content) == :collaborating
    end

    test "a token in a ~S sigil moduledoc counts" do
      content = "defmodule X do\n  @moduledoc ~S\"\"\"\n  hearth:owned\n  \"\"\"\nend\n"
      assert Ownership.classify(content) == :owned
    end

    test ":owned wins when a moduledoc carries both tokens" do
      content = "defmodule X do\n  @moduledoc \"hearth:owned hearth:collaborating\"\nend\n"
      assert Ownership.classify(content) == :owned
    end

    test "a token embedded in a longer word does not match" do
      content = "defmodule X do\n  @moduledoc \"nothearth:ownedx is unrelated\"\nend\n"
      assert Ownership.classify(content) == :none
    end
  end

  # A spec description copied into a Layer 2 `@doc`, or a mention in a
  # comment or string, must not change who owns the file.
  describe "classify/1 outside the moduledoc" do
    test "a token in a @doc is ignored" do
      content = """
      defmodule X.Api do
        @moduledoc "Behaviour."

        @doc "Mark your file hearth:owned to keep edits."
        def list(opts \\\\ []), do: opts
      end
      """

      assert Ownership.classify(content) == :none
    end

    test "a token in a comment or a string literal is ignored" do
      content = """
      defmodule X do
        @moduledoc false
        # hearth:owned
        def token, do: "hearth:collaborating"
      end
      """

      assert Ownership.classify(content) == :none
    end

    test "a file that doesn't parse falls back to a whole-file scan (fails safe)" do
      assert Ownership.classify("defmodule X do\n  # hearth:owned\n  def broken(\n") == :owned
    end
  end
end
