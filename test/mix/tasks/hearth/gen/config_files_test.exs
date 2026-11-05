defmodule Mix.Tasks.Hearth.Gen.ConfigFilesTest do
  use Hearth.TaskCase, async: true

  # Which config files gen's wiring creates. Hearth configures
  # `config/test.exs` and `config/runtime.exs` (and comments in
  # `config/config.exs`); it never needs `config/dev.exs` or
  # `config/prod.exs`, so it must not create them empty.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @spec_path "priv/specs/petstore.yaml"
  @prod "config/prod.exs"
  @dev "config/dev.exs"

  # A Phoenix-style `config/` tree: config.exs ends by importing the
  # env's file.
  @config_exs """
  import Config

  config :test, ecto_repos: [Test.Repo]

  # Import environment specific config. This must remain at the bottom
  # of this file so it overrides the configuration defined above.
  import_config "\#{config_env()}.exs"
  """

  @dev_exs """
  import Config

  config :test, Test.Repo, database: "test_dev"
  """

  @test_exs """
  import Config

  config :test, Test.Repo, database: "test_test", pool: Ecto.Adapters.SQL.Sandbox
  """

  @prod_exs """
  import Config

  config :logger, level: :info
  """

  @phoenix %{
    "config/config.exs" => @config_exs,
    "config/dev.exs" => @dev_exs,
    "config/test.exs" => @test_exs,
    "config/prod.exs" => @prod_exs
  }

  defp gen(files) do
    test_project(files: Map.put(files, @spec_path, @petstore_3_0_yaml))
    |> Igniter.compose_task("hearth.gen", [@spec_path, "--integration", "Petstore"])
  end

  describe "a mix new project (no config/)" do
    test "gen creates no config/prod.exs or config/dev.exs" do
      %{}
      |> gen()
      |> refute_creates(@prod)
      |> refute_creates(@dev)
    end

    test "config/test.exs gets the test config and config/config.exs loads it" do
      igniter = gen(%{})

      assert created_file(igniter, "config/test.exs") =~
               "impl: Test.Integrations.Petstore.PetstoreApi.Mock"

      config = created_file(igniter, "config/config.exs")
      assert config =~ ~s(import_config "test.exs")
      refute config =~ "config_env()}.exs"
    end
  end

  describe "a Phoenix-style config/" do
    test "with a prod.exs: it is left alone" do
      @phoenix
      |> gen()
      |> assert_unchanged([@prod, @dev, "config/config.exs"])
    end

    test "without a prod.exs: gen doesn't create one" do
      @phoenix
      |> Map.delete(@prod)
      |> gen()
      |> refute_creates(@prod)
      |> assert_unchanged([@dev, "config/config.exs"])
    end

    test "without a dev.exs: gen doesn't create one" do
      @phoenix
      |> Map.delete(@dev)
      |> gen()
      |> refute_creates(@dev)
      |> assert_unchanged(@prod)
    end

    test "with an empty prod.exs: it is left alone" do
      @phoenix
      |> Map.put(@prod, "")
      |> gen()
      |> assert_unchanged(@prod)
    end

    test "the test config lands in the existing test.exs" do
      test_config = @phoenix |> gen() |> created_file("config/test.exs")

      assert test_config =~ "pool: Ecto.Adapters.SQL.Sandbox"
      assert test_config =~ "impl: Test.Integrations.Petstore.PetstoreApi.Mock"
    end
  end

  describe "a config.exs that imports test.exs only in test" do
    @test_only_config """
    import Config

    if config_env() == :test do
      import_config "test.exs"
    end
    """

    test "gains no second import and no dev.exs or prod.exs" do
      %{"config/config.exs" => @test_only_config, "config/test.exs" => @test_exs}
      |> gen()
      |> assert_unchanged("config/config.exs")
      |> refute_creates(@prod)
      |> refute_creates(@dev)
    end
  end

  describe "regen" do
    @pruned %{
      "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
      ".hearth.exs" => "[integrations: [petstore: [module: Test.Integrations.Petstore]]]"
    }

    defp regen(files, argv) do
      test_project(files: Map.merge(@phoenix, files) |> Map.delete(@prod))
      |> Igniter.compose_task("hearth.regen", argv)
    end

    test "a plain regen doesn't create config/prod.exs" do
      @pruned
      |> regen(["petstore"])
      |> refute_creates(@prod)
    end

    test "--module doesn't create config/prod.exs" do
      igniter = regen(@pruned, ["petstore", "--module", "Test.Billing.Petstore"])

      assert created_file(igniter, "config/test.exs") =~
               "impl: Test.Billing.Petstore.PetstoreApi.Mock"

      igniter
      |> refute_creates(@prod)
      |> assert_unchanged("config/config.exs")
    end
  end
end
