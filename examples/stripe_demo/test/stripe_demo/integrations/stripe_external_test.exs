defmodule StripeDemo.Integrations.StripeExternalTest do
  @moduledoc false

  # Generated once by Hearth — a scaffold for real HTTP calls
  # against the live API. Hearth never overwrites this file; edit
  # it freely. Tagged `:external` and skipped by `mix test` — run
  # it with `mix test --include external`.

  use ExUnit.Case, async: true

  @moduletag :external

  alias StripeDemo.Integrations.Stripe.StripeApi

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_customers reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.get_customers([])
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "post_customers reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.post_customers([])
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_customers_customer reaches the live API" do
    assert {:ok, %Req.Response{}} = StripeApi.Req.get_customers_customer("TODO", [])
  end
end
