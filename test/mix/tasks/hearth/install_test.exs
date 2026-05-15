defmodule Mix.Tasks.Hearth.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "formatter" do
    test "adds :hearth to import_deps in .formatter.exs" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:hearth]
      """)
    end
  end

  describe ":hearth_domains config" do
    test "initializes :hearth_domains to [] when unset" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_creates("config/config.exs", """
      import Config
      config :test, hearth_domains: []
      """)
    end

    test "preserves an explicit false opt-out on re-run" do
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, :hearth_domains, false
          """
        }
      )
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged("config/config.exs")
    end

    test "preserves a populated :hearth_domains list on re-run" do
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, :hearth_domains, [MyApp.Billing.Stripe]
          """
        }
      )
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged("config/config.exs")
    end
  end

  describe "idempotency" do
    test "running twice in a row is a no-op" do
      test_project()
      |> Igniter.compose_task("hearth.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.install", [])
      |> assert_unchanged()
    end
  end
end
