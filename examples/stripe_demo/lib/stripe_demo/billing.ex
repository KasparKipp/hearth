defmodule StripeDemo.Billing do
  @moduledoc """
  Business logic on top of the generated Stripe client. It calls the
  behaviour, `StripeApi`, so tests can stub it with `StripeApi.Mock`.
  """

  alias StripeDemo.Integrations.Stripe.StripeApi

  @doc "The status of a Stripe subscription, e.g. `\"active\"`."
  @spec subscription_status(String.t()) :: {:ok, String.t()} | {:error, term()}
  def subscription_status(subscription_id) do
    case StripeApi.get_subscription(subscription_id) do
      {:ok, %Req.Response{status: 200, body: %{"status" => status}}} -> {:ok, status}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
