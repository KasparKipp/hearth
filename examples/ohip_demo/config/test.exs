import Config

config :ohip_demo, OhipDemo.Integrations.OhipOauth, base_url: "https://api.example.com/oauth/v1"

config :ohip_demo, OhipDemo.Integrations.OhipOauth.OhipOauthApi,
  impl: OhipDemo.Integrations.OhipOauth.OhipOauthApi.Mock

config :ohip_demo, OhipDemo.Integrations.Ohip, base_url: "https://api.example.com"

config :ohip_demo, OhipDemo.Integrations.Ohip.OhipApi,
  impl: OhipDemo.Integrations.Ohip.OhipApi.Mock
