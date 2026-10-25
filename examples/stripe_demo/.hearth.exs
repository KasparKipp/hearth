# Stripe's spec has no tags, so `--tag` has nothing to select from.
# These overrides tag the operations this demo uses; `mix hearth.gen`
# applies them, keeps them, and fills in the rest of the entry.
[
  integrations: [
    stripe: [
      overrides: [
        tags: [
          Customers: ["get /v1/customers", "post /v1/customers", "get /v1/customers/{customer}"],
          Subscriptions: ["/v1/subscriptions*"]
        ]
      ]
    ]
  ]
]
