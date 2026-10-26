defmodule Mix.Tasks.Hearth.Gen.BaseUrlTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: base URLs: multiple servers and the shared base path.

  describe "multi-server base URLs" do
    defp server_spec(urls) do
      JSON.encode!(%{
        "openapi" => "3.0.0",
        "info" => %{"title" => "Multi", "version" => "1.0"},
        "servers" => Enum.map(urls, &%{"url" => &1}),
        "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}}
      })
    end

    defp gen_servers(urls) do
      test_project(files: %{"priv/specs/m.json" => server_spec(urls)})
      |> Igniter.compose_task("hearth.gen", ["priv/specs/m.json", "--integration", "Acme"])
    end

    test "the prod server is Layer 1's @base_url; the non-prod one goes to config/test.exs" do
      igniter = gen_servers(["https://staging.acme.com", "https://api.acme.com"])

      assert created_file(igniter, "lib/test/integrations/acme.ex") =~
               ~s(@base_url "https://api.acme.com")

      assert created_file(igniter, "config/test.exs") =~
               ~s(base_url: "https://staging.acme.com")
    end

    test "extra prod servers become commented overrides in config/config.exs" do
      igniter =
        gen_servers(["https://api.acme.com", "https://eu.acme.com", "https://staging.acme.com"])

      config = created_file(igniter, "config/config.exs")
      assert config =~ "# Hearth: alternate base URLs"
      assert config =~ ~s(base_url: "https://eu.acme.com")
    end

    test "extra non-prod servers become commented options in config/test.exs" do
      igniter =
        gen_servers([
          "https://api.acme.com",
          "https://staging.acme.com",
          "https://dev.acme.com"
        ])

      test_config = created_file(igniter, "config/test.exs")
      assert test_config =~ "# Hearth: alternate base URLs"
      assert test_config =~ ~s(base_url: "https://dev.acme.com")
    end

    test "a spec with no servers emits a base-URL warning" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "NoServers", "version" => "1.0"},
          "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}}
        })

      igniter =
        test_project(files: %{"priv/specs/n.json" => spec})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/n.json", "--integration", "Acme"])

      assert Enum.any?(igniter.warnings, &String.contains?(&1, "declared no `servers`"))
    end
  end

  describe "shared base path" do
    @versioned_spec JSON.encode!(%{
                      "openapi" => "3.0.0",
                      "info" => %{"title" => "Versioned", "version" => "1.0"},
                      "servers" => [%{"url" => "https://api.example.com"}],
                      "paths" => %{
                        "/api/v1/customers" => %{
                          "get" => %{"operationId" => "listCustomers", "tags" => ["Customers"]}
                        },
                        "/api/v1/customers/{id}" => %{
                          "get" => %{
                            "operationId" => "getCustomer",
                            "tags" => ["Customers"],
                            "parameters" => [%{"name" => "id", "in" => "path"}]
                          }
                        }
                      }
                    })

    test "a path prefix shared by every operation is folded into the base URL" do
      igniter =
        test_project(files: %{"priv/specs/versioned.json" => @versioned_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/versioned.json",
          "--integration",
          "Versioned"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/versioned.ex")
      assert layer1 =~ ~s(@base_url "https://api.example.com/api/v1")

      layer3 = created_file(igniter, "lib/test/integrations/versioned/versioned_api/req.ex")
      assert layer3 =~ "Versioned.request(\"/customers\", opts)"
      assert layer3 =~ "Versioned.request(\"/customers/\#{id}\", opts)"
    end

    @no_servers_spec JSON.encode!(%{
                       "openapi" => "3.0.0",
                       "info" => %{"title" => "Serverless", "version" => "1.0"},
                       "paths" => %{
                         "/v3/notices" => %{
                           "get" => %{"operationId" => "listNotices", "tags" => ["Notices"]}
                         },
                         "/v3/notices/search" => %{
                           "get" => %{"operationId" => "searchNotices", "tags" => ["Notices"]}
                         }
                       }
                     })

    test "a relative server's path joins the placeholder, ahead of the shared prefix" do
      spec = @no_servers_spec |> JSON.decode!() |> Map.put("servers", [%{"url" => "/api"}])

      igniter =
        test_project(files: %{"priv/specs/srv.json" => JSON.encode!(spec)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/srv.json", "--integration", "Srv"])

      layer1 = created_file(igniter, "lib/test/integrations/srv.ex")
      assert layer1 =~ "# TODO: the spec declared no `servers`"
      assert layer1 =~ ~s(@base_url "https://api.example.com/api/v3")

      assert created_file(igniter, "config/test.exs") =~
               ~s(base_url: "https://api.example.com/api/v3")

      assert Enum.any?(igniter.warnings, &String.contains?(&1, "https://api.example.com/api/v3"))
    end

    test "the prefix folds into the base-URL placeholder when the spec has no servers" do
      igniter =
        test_project(files: %{"priv/specs/srv.json" => @no_servers_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/srv.json",
          "--integration",
          "Srv"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/srv.ex")
      assert layer1 =~ "# TODO: the spec declared no `servers`"
      assert layer1 =~ ~s(@base_url "https://api.example.com/v3")

      layer3 = created_file(igniter, "lib/test/integrations/srv/srv_api/req.ex")
      assert layer3 =~ "Srv.request(\"/notices\", opts)"
      assert layer3 =~ "Srv.request(\"/notices/search\", opts)"
    end

    @templated_prefix_spec JSON.encode!(%{
                             "openapi" => "3.0.0",
                             "info" => %{"title" => "Accounts", "version" => "1.0"},
                             "servers" => [%{"url" => "https://api.example.com"}],
                             "paths" => %{
                               "/v1/accounts/{account_id}/charges" => %{
                                 "get" => %{
                                   "operationId" => "listCharges",
                                   "parameters" => [%{"name" => "account_id", "in" => "path"}]
                                 }
                               },
                               "/v1/accounts/{account_id}/payouts" => %{
                                 "get" => %{
                                   "operationId" => "listPayouts",
                                   "parameters" => [%{"name" => "account_id", "in" => "path"}]
                                 }
                               }
                             }
                           })

    test "a shared path param stays in the operation path, not the base URL" do
      igniter =
        test_project(files: %{"priv/specs/accounts.json" => @templated_prefix_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/accounts.json",
          "--integration",
          "Accounts"
        ])

      layer1 = created_file(igniter, "lib/test/integrations/accounts.ex")
      assert layer1 =~ ~s(@base_url "https://api.example.com/v1/accounts")

      layer3 = created_file(igniter, "lib/test/integrations/accounts/accounts_api/req.ex")
      assert layer3 =~ "def list_charges(account_id, opts \\\\ [])"
      assert layer3 =~ "Accounts.request(\"/\#{account_id}/charges\", opts)"
    end
  end
end
