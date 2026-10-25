defmodule Hearth.UsageRulesTest do
  use ExUnit.Case, async: true

  # `usage-rules.md` ships with the hex package (declared in
  # mix.exs `package.files`) and is the contract a downstream
  # consumer's AI agent reads to learn how to use Hearth. These
  # tests lock in the load-bearing content so a future edit cannot
  # silently strip a section.

  @path "usage-rules.md"
  @content File.read!(@path)

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

  test "explains the x-hearth block in the pruned spec" do
    assert @content =~ "x-hearth"
    assert @content =~ "base_path"
    assert @content =~ "`module`"
  end

  test "regen takes integration names or --all, not a module" do
    assert @content =~ "mix hearth.regen stripe"
    assert @content =~ "mix hearth.regen --all"
    refute @content =~ "mix hearth.regen <App>"
  end

  test "documents where credentials come from" do
    assert @content =~ "## Credentials"
    assert @content =~ "StripeApi.list_customers(api_key: tenant.stripe_key)"
    assert @content =~ "api_key: {MyApp.Vault, :fetch!, [\"stripe\"]}"
  end

  test "documents moving an integration with --module" do
    assert @content =~ "mix hearth.regen stripe --module MyApp.Payments.Stripe"
    assert @content =~ "--module MyApp.Payments.Stripe --remove-old"
  end

  test "documents the Mox test seam at <Layer2>.Mock" do
    assert @content =~ "Mox"
    assert @content =~ ".Mock"
  end

  test "documents the :external opt-in test tag" do
    assert @content =~ ":external"
    assert @content =~ "mix test --include external"
  end

  test "says only local spec files generate code today" do
    assert @content =~ "Only local spec files generate code today"
    refute @content =~ "HTTP fetcher coming soon"
  end

  test "setup tells consumers to add igniter, an optional dependency of Hearth" do
    assert @content =~ ~s({:igniter, "~> 0.5", only: [:dev, :test]})
  end

  test "shows valid :hearth_domains config syntax" do
    assert @content =~ "hearth_domains: []"
    refute @content =~ "hearth_domains, []"
  end

  test "does not call :hearth_domains 'the registry' (that is the shortcut registry)" do
    refute @content =~ "The registry — `:hearth_domains`"
  end

  test "start-over instructions do not assume the default Integrations domain" do
    refute @content =~ "lib/<app>/integrations/<int>*"
    refute @content =~ "test/<app>/integrations/<int>*"
  end

  test "describes --n-operations as the generate-everything bypass" do
    refute @content =~ "tag-less subset"
    assert @content =~ "--n-operations"
  end

  test "warns that owning Layer 2 can desync it from a regenerated Layer 3" do
    assert @content =~ "out of sync"
  end
end
