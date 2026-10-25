import Config

config :stripe_demo, StripeDemo.Integrations.Stripe, base_url: "https://api.stripe.com/v1"

config :stripe_demo, StripeDemo.Integrations.Stripe.StripeApi,
  impl: StripeDemo.Integrations.Stripe.StripeApi.Mock
