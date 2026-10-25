defmodule HearthTest do
  use ExUnit.Case, async: true

  # `Hearth` is the hex docs front door — lock in that it introduces the
  # three tasks rather than the `mix new` stub.
  test "the moduledoc introduces the three Mix tasks" do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Hearth)

    assert moduledoc =~ "mix hearth.install"
    assert moduledoc =~ "mix hearth.gen"
    assert moduledoc =~ "mix hearth.regen"
  end
end
