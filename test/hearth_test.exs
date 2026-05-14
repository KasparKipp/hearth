defmodule HearthTest do
  use ExUnit.Case
  doctest Hearth

  test "greets the world" do
    assert Hearth.hello() == :world
  end
end
