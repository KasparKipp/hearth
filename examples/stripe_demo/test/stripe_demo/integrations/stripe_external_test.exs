defmodule StripeDemo.Integrations.StripeExternalTest do
  @moduledoc false

  # Generated once by Hearth — a scaffold for real HTTP calls
  # against the live API. Hearth never overwrites this file; edit
  # it freely. Tagged `:external` and skipped by `mix test` — run
  # it with `mix test --include external`.

  use ExUnit.Case, async: false

  @moduletag :external

  alias StripeDemo.Integrations.Stripe.StripeApi
  @client StripeDemo.Integrations.Stripe

  setup do
    # Merge into the existing config — `config/test.exs` sets a
    # `:base_url` on @client; a bare `put_env` would wipe it and the
    # external test would hit production.
    previous = Application.get_env(:stripe_demo, @client, [])
    api_key = System.get_env("STRIPE_API_KEY") || "DEV_NO_STRIPE_API_KEY"
    Application.put_env(:stripe_demo, @client, Keyword.put(previous, :api_key, api_key))
    on_exit(fn -> Application.put_env(:stripe_demo, @client, previous) end)
    :ok
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "list_customers reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.list_customers([])
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "create_customer reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.create_customer([])
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "retrieve reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.retrieve("cus_TODO", [])
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_subscription reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.get_subscription("TODO", [])
  end
end
