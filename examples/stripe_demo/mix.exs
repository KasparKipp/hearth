defmodule StripeDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :stripe_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # `:req` and `:mox` are added by `mix hearth.gen`. `:plug` lets the
  # generated `Req.Test` auth test compile.
  defp deps do
    [
      {:hearth, path: "../..", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
