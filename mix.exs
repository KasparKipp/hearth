defmodule Hearth.MixProject do
  use Mix.Project

  @version "0.0.1"

  def project do
    [
      app: :hearth,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      package: package(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test) do
    elixirc_paths(:dev) ++ ["test/support"]
  end

  defp elixirc_paths(_env) do
    ["lib"]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      maintainers: [
        "Kaspar Kipp <kaspar.kipp@gmail.com>"
      ],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*
      CHANGELOG* usage-rules.md),
      links: %{
        "GitHub" => "https://github.com/todo-project/hearth"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:igniter, "~> 0.5", optional: true},
      {:yaml_elixir, "~> 2.0"},
      # Referenced by generated code, not by Hearth itself — optional so
      # they are not forced on consumers transitively. `req` is the
      # runtime of the generated client; `plug` backs the `Req.Test`
      # plug in the generated Layer 1 test.
      {:req, "~> 0.5", optional: true},
      {:plug, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      credo: "credo --strict"
    ]
  end
end
