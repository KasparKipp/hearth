defmodule Hearth.UsageRulesTest do
  use ExUnit.Case, async: true

  # `usage-rules.md` ships with the hex package (declared in
  # mix.exs `package.files`) and is the contract a downstream
  # consumer's AI agent reads to learn how to use Hearth. These
  # tests lock in the load-bearing content so a future edit cannot
  # silently strip a section.

  @path "usage-rules.md"
  @content File.read!(@path)

  test "ships at the repo root" do
    assert File.exists?(@path)
  end

  test "documents the three Mix tasks" do
    assert @content =~ "mix hearth.install"
    assert @content =~ "mix hearth.gen"
    assert @content =~ "mix hearth.regen"
  end

  test "documents the create-only contract and points re-runs at regen" do
    assert @content =~ "create-only"
    assert @content =~ "use `mix hearth.regen`"
  end

  test "documents both ownership tokens" do
    assert @content =~ "hearth:owned"
    assert @content =~ "hearth:collaborating"
  end

  test "names the pruned spec as the regen source of truth" do
    assert @content =~ "priv/hearth/"
    assert @content =~ "pruned"
  end

  test "documents the Mox test seam at <Layer2>.Mock" do
    assert @content =~ "Mox"
    assert @content =~ ".Mock"
  end

  test "documents the :external opt-in test tag" do
    assert @content =~ ":external"
    assert @content =~ "mix test --include external"
  end
end
