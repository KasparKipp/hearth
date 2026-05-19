defmodule Hearth.Fs.OwnershipTest do
  use ExUnit.Case, async: true

  alias Hearth.Fs.Ownership

  describe "classify/1" do
    test "a file with no token is :none" do
      assert Ownership.classify("defmodule X do\n  @moduledoc \"raw client\"\nend\n") == :none
    end

    test "a hearth:owned token is :owned" do
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

    test "a hearth:collaborating token is :collaborating" do
      assert Ownership.classify("@moduledoc \"hearth:collaborating\"") == :collaborating
    end

    test ":owned wins when a file carries both tokens" do
      assert Ownership.classify("hearth:owned hearth:collaborating") == :owned
    end

    test "a token embedded in a longer word does not match" do
      assert Ownership.classify("# nothearth:ownedx is unrelated") == :none
    end
  end
end
