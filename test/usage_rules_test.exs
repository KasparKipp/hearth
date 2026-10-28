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
    assert @content =~ "Only the `@moduledoc` counts"
  end

  test "names the pruned spec as the regen source of truth" do
    assert @content =~ "priv/hearth/"
    assert @content =~ "pruned"
  end

  test "explains the .hearth.exs entry" do
    assert @content =~ ".hearth.exs"
    assert @content =~ "base_path"
    assert @content =~ "`module`"
    assert @content =~ "`tags`"
    assert @content =~ "untagged:"
    refute @content =~ "x-hearth"
  end

  test "selection changes go through tags: and regen --sync, not pruned-spec edits" do
    assert @content =~ "mix hearth.regen stripe --sync"
    assert @content =~ "`tags:`"
    refute @content =~ "edit `priv/hearth/<int>.yaml` and"
  end

  test "documents tag overrides" do
    assert @content =~ "## Overrides"
    assert @content =~ ~s|Subscriptions: ["/v1/subscriptions*"]|
    assert @content =~ "matches nothing"
    assert @content =~ ~s|operation_ids: %{"GetCustomersCustomer" => "GetCustomer"}|
    assert @content =~ ~s|"/security" => [%{"bearerAuth" => []}]|
    assert @content =~ "## Auth"
    assert @content =~ ~s|scheme: "bearerAuth"|
    assert @content =~ "HTTP basic only when nothing else is"
    refute @content =~ "http/basic (not supported)"
  end

  test "documents --sync renaming call sites" do
    assert @content =~ "asks to rename its calls in lib and test"
  end

  test "documents prefixed ids" do
    assert @content =~ "## Prefixed ids"
    assert @content =~ ~s|StripeApi.retrieve("cus_123")|
  end

  test "documents Swagger 2.0 input" do
    assert @content =~ "A Swagger 2.0 source is converted to OpenAPI 3.0 first."
  end

  test "documents sources:" do
    assert @content =~ "## Several sources"
    assert @content =~ ~s|sources: [items: "priv/specs/items.json", orders: "orders@1.2"]|
    assert @content =~ ~s|overrides: [shared: %{"schemas/address" =>|
  end

  test "documents headers" do
    assert @content =~ "## Headers"
    assert @content =~ ~s|headers: ["stripe-account": :account]|
  end

  test "documents where values come from" do
    assert @content =~ "## Where values come from"
    assert @content =~ "credential: [resolve: {MyApp.Tenancy, :token}, options: [:tenant]]"
    assert @content =~ ~s|"x-tenant-id": [option: :tenant_id]|
    assert @content =~ "base_url: :base_url"
  end

  test "documents hearth.diff for CI" do
    assert @content =~ "mix hearth.diff stripe"
    assert @content =~ "--fail-on breaking"
    assert @content =~ "source_sha256"
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

  test "says files, URLs and registry shortcuts all generate code" do
    assert @content =~ "All three generate code"
    assert @content =~ "registry: %{"
    refute @content =~ "Only local spec files"
    refute @content =~ "coming soon"
  end

  test "setup tells consumers to add igniter, an optional dependency of Hearth" do
    assert @content =~ ~s({:igniter, "~> 0.5", only: [:dev, :test]})
  end

  test "does not mention :hearth_domains (dropped)" do
    refute @content =~ "hearth_domains"
  end

  test "start-over instructions do not assume the default Integrations domain" do
    refute @content =~ "lib/<app>/integrations/<int>*"
    refute @content =~ "test/<app>/integrations/<int>*"
  end

  test "no Stripe --tag example (its spec tags nothing), no local-only --sync" do
    refute @content =~ ~s(--tag "Customers:GetCustomers")
    refute @content =~ "must be a local spec file"
  end

  test "says a header the auth scheme sends halts gen and regen" do
    assert @content =~ "A header the auth scheme sends"
  end

  test "says a malformed .hearth.exs halts, naming the entry and key" do
    assert @content =~ "an unknown key or a malformed value halts, naming the entry\nand the key"
    assert @content =~ "nothing in it runs"
  end

  test "mentions every .hearth.exs key the schema accepts" do
    for key <- Hearth.Config.Schema.keys() do
      assert @content =~ ~r/\b#{key}:/, "usage-rules.md never mentions `#{key}:`"
    end
  end

  test "says regen offers to set up values the external test lacks" do
    assert @content =~ "asks to add a `setup` block seeding it"
  end

  test "describes --n-operations as the generate-everything bypass" do
    refute @content =~ "tag-less subset"
    assert @content =~ "--n-operations"
  end

  test "warns that owning Layer 2 can desync it from a regenerated Layer 3" do
    assert @content =~ "out of sync"
  end
end
