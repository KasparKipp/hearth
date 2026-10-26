defmodule StripeDemo.BillingTest do
  use ExUnit.Case, async: true

  import Mox

  alias StripeDemo.Billing
  alias StripeDemo.Integrations.Stripe.StripeApi

  setup :verify_on_exit!

  test "subscription_status/1 reads the status Stripe returns" do
    expect(StripeApi.Mock, :get_subscription, fn "sub_123", [] ->
      {:ok, %Req.Response{status: 200, body: %{"status" => "active"}}}
    end)

    assert Billing.subscription_status("sub_123") == {:ok, "active"}
  end

  test "subscription_status/1 passes an HTTP error on" do
    stub(StripeApi.Mock, :get_subscription, fn _id, _opts ->
      {:ok, %Req.Response{status: 404, body: %{}}}
    end)

    assert Billing.subscription_status("sub_404") == {:error, {:http, 404}}
  end
end
