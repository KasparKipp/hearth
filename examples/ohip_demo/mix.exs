defmodule OhipDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :ohip_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:mox, "~> 1.0", only: [:test]},
      {:req, "~> 0.7"},
      {:hearth, path: "../..", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:plug, "~> 1.0", only: :test}
    ]
  end

  defp elixirc_paths(:test),
    do: elixirc_paths(:dev) ++ ["test/support"]

  defp elixirc_paths(_),
    do: ["lib"]
end
