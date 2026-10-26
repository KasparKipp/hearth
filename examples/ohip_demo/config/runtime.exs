import Config

if config_env() == :prod do
  config :ohip_demo, OhipDemo.Integrations.Ohip,
    app_key: System.get_env("OHIP_APP_KEY") || raise("missing OHIP_APP_KEY environment variable")
end

if config_env() == :dev do
  config :ohip_demo, OhipDemo.Integrations.Ohip,
    app_key: System.get_env("OHIP_APP_KEY") || "DEV_NO_OHIP_APP_KEY"
end
