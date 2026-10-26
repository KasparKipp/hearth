import Config

config :ohip_demo, OhipDemo.Integrations.Ohip, base_url: "https://api.example.com"

config :ohip_demo, OhipDemo.Integrations.Ohip.OhipApi,
  impl: OhipDemo.Integrations.Ohip.OhipApi.Mock
