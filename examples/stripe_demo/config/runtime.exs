import Config

if config_env() == :prod do
  config :stripe_demo, StripeDemo.Integrations.Stripe,
    api_key:
      System.get_env("STRIPE_API_KEY") || raise("missing STRIPE_API_KEY environment variable")
end

if config_env() == :dev do
  config :stripe_demo, StripeDemo.Integrations.Stripe,
    api_key: System.get_env("STRIPE_API_KEY") || "DEV_NO_STRIPE_API_KEY"
end
