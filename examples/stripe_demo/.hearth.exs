# Stripe's spec has no tags, so `--tag` has nothing to select from.
# These overrides tag the operations this demo uses and give them
# shorter names; `mix hearth.gen` applies them, keeps them, and fills
# in the rest of the entry.
[
  integrations: [
    stripe: [
      module: StripeDemo.Integrations.Stripe,
      source: "stripe@2026-04-22.dahlia",
      source_sha256: "4d801316f5789bc0ad4bb0f4dccfe9d672e011cf44aa888a60a285b90fd96c76",
      overrides: [
        tags: [
          Customers: ["get /v1/customers", "post /v1/customers", "get /v1/customers/{customer}"],
          Subscriptions: ["/v1/subscriptions*"]
        ],
        operation_ids: %{
          "GetCustomers" => "ListCustomers",
          "PostCustomers" => "CreateCustomer",
          "GetCustomersCustomer" => "GetCustomer"
        }
      ],
      base_path: "/v1",
      tags: [Subscriptions: :none, Customers: :all],
      untagged: :none,
      auth: [
        scheme: "bearerAuth",
        available: [basicAuth: "http/basic (not supported)", bearerAuth: "bearer"]
      ]
    ]
  ]
]
