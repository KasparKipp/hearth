defmodule Mix.Tasks.Hearth.RegenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  @layer1 "lib/test/integrations/petstore.ex"
  @layer2 "lib/test/integrations/petstore/petstore_api.ex"
  @layer3 "lib/test/integrations/petstore/petstore_api/req.ex"
  @external "test/test/integrations/petstore_external_test.exs"

  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  defp created_file(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  defp owned_layer1 do
    """
    defmodule Test.Integrations.Petstore do
      @moduledoc \"\"\"
      Raw client.

      hearth:owned
      \"\"\"
      def hand_written, do: :mine
    end
    """
  end

  defp regen(igniter),
    do: Igniter.compose_task(igniter, "hearth.regen", ["Test.Integrations.Petstore"])

  describe "the pruned spec" do
    test "regenerates the layers from priv/hearth/<name>.yaml" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @layer2)
      assert_creates(igniter, @layer3)

      assert created_file(igniter, @layer1) =~ "defmodule Test.Integrations.Petstore do"
      assert created_file(igniter, @layer2) =~ "@callback list_pets("
    end

    test "halts when the pruned spec is missing" do
      igniter =
        test_project()
        |> regen()

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "no pruned spec for Petstore") and
                 String.contains?(issue, "priv/hearth/petstore.yaml")
             end)
    end

    test "halts with a helpful message when no integration is named" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.regen", [])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "name the integration's Layer 1 module") and
                 String.contains?(issue, "MyApp.Integrations.Stripe")
             end)
    end
  end

  describe "regen right after gen" do
    # Full spec prefix is `/v1`; the `Customers` subset alone shares
    # `/v1/customers`. regen must reuse gen's prefix, not recompute it
    # from the pruned subset — config/test.exs carries gen's base URL.
    @subset_prefix_spec JSON.encode!(%{
                          "openapi" => "3.0.0",
                          "info" => %{"title" => "Shop", "version" => "1.0"},
                          "servers" => [%{"url" => "https://api.example.com"}],
                          "paths" => %{
                            "/v1/customers/list" => %{
                              "get" => %{
                                "operationId" => "listCustomers",
                                "tags" => ["Customers"]
                              }
                            },
                            "/v1/customers/search" => %{
                              "get" => %{
                                "operationId" => "searchCustomers",
                                "tags" => ["Customers"]
                              }
                            },
                            "/v1/orders/list" => %{
                              "get" => %{"operationId" => "listOrders", "tags" => ["Orders"]}
                            }
                          }
                        })

    defp gen_then_regen(files, gen_args, layer1) do
      test_project(files: files)
      |> Igniter.compose_task("hearth.gen", gen_args)
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", [layer1])
    end

    test "is a no-op" do
      %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml}
      |> gen_then_regen(
        ["priv/specs/petstore.yaml", "--integration", "Petstore"],
        "Test.Integrations.Petstore"
      )
      |> assert_unchanged()
    end

    test "gen records the base path and source in the pruned spec" do
      igniter =
        test_project(files: %{"priv/specs/shop.json" => @subset_prefix_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/shop.json",
          "--integration",
          "Shop",
          "--tag",
          "Customers"
        ])

      {:ok, pruned} =
        created_file(igniter, "priv/hearth/shop.yaml") |> YamlElixir.read_from_string()

      assert pruned["x-hearth"] == %{"base_path" => "/v1", "source" => "priv/specs/shop.json"}
    end

    test "halts when an edited pruned spec has a path outside the recorded base path" do
      pruned = """
      openapi: 3.0.0
      info: {title: Shop, version: "1.0"}
      paths:
        /v1/customers/list:
          get: {operationId: listCustomers}
        /v2/customers/list:
          get: {operationId: listCustomersV2}
      x-hearth: {base_path: /v1, source: priv/specs/shop.json}
      """

      igniter =
        test_project(files: %{"priv/hearth/shop.yaml" => pruned})
        |> Igniter.compose_task("hearth.regen", ["Test.Integrations.Shop"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "/v1") and String.contains?(issue, "/v2/customers/list")
             end)
    end

    test "is a no-op when the selected subset shares a longer path prefix" do
      %{"priv/specs/shop.json" => @subset_prefix_spec}
      |> gen_then_regen(
        ["priv/specs/shop.json", "--integration", "Shop", "--tag", "Customers"],
        "Test.Integrations.Shop"
      )
      |> assert_unchanged()
    end
  end

  describe "ownership tokens" do
    test "a hearth:owned file is skipped, keeping its hand-edits" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => owned_layer1()
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      refute created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "skipping #{@layer1} (hearth:owned)"
    end

    test "a file with no token is overwritten" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => "defmodule Test.Integrations.Petstore do\nend\n"
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end

    test "a hearth:collaborating file is regenerated when the prompt is accepted" do
      collaborating =
        "defmodule Test.Integrations.Petstore do\n  @moduledoc \"hearth:collaborating\"\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => collaborating
          }
        )
        |> regen()

      # test mode auto-accepts the per-file prompt
      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end
  end

  describe "the external test scaffold" do
    test "is created when absent" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert_creates(igniter, @external)
    end

    test "is never overwritten — even without an ownership token" do
      edited = "defmodule Test.Integrations.PetstoreExternalTest do\n  # user edited\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @external => edited
          }
        )
        |> regen()

      assert created_file(igniter, @external) =~ "# user edited"
      assert notice_text(igniter) =~ "keeping #{@external}"
    end
  end
end
