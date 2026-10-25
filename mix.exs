defmodule Hearth.MixProject do
  use Mix.Project

  @version "0.0.1"

  def project do
    [
      app: :hearth,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      package: package(),
      docs: docs(),
      deps: deps(),
      name: "Hearth",
      description: "Mix tasks that generate three-layer Req HTTP clients from OpenAPI specs.",
      source_url: "https://github.com/KasparKipp/hearth"
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
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
        "GitHub" => "https://github.com/KasparKipp/hearth"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "usage-rules.md", "LICENSE"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:igniter, "~> 0.5", optional: true},
      {:yaml_elixir, "~> 2.0"},
      # `ymlr` writes the pruned spec back out as YAML — `yaml_elixir`
      # only reads. (`open_api_spex` was evaluated for parsing/
      # validation and rejected: it has no spec-pruning, and its
      # decoder raises on OAS 3.1 specs, which Hearth must support.)
      {:ymlr, "~> 5.0"},
      # Referenced by generated code, not by Hearth itself — optional so
      # they are not forced on consumers transitively. `req` is the
      # runtime of the generated client; `plug` backs the `Req.Test`
      # plug in the generated Layer 1 test. (`mox`, for the generated
      # mock, is added straight to the consumer by `mix hearth.gen`.)
      {:req, "~> 0.7", optional: true},
      {:plug, "~> 1.0", optional: true},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        # Security: scan locked deps for known CVEs and retired packages.
        "deps.audit",
        fn _ -> Mix.ensure_application!(:hex) end,
        "hex.audit",
        "test --cover --export-coverage default",
        "crap"
      ]
    ]
  end
end
