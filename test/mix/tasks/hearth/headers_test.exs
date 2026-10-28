defmodule Mix.Tasks.Hearth.HeadersTest do
  use Hearth.TaskCase, async: true

  # `headers:` in a `.hearth.exs` entry, across gen and regen. Every
  # operation of the spec requires an `X-Tenant-Id` header; auth is a
  # bearer token.

  @spec_json JSON.encode!(%{
               "openapi" => "3.0.0",
               "info" => %{"title" => "Shop", "version" => "1"},
               "servers" => [%{"url" => "https://api.shop.test"}],
               "security" => [%{"bearerAuth" => []}],
               "components" => %{
                 "securitySchemes" => %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}},
                 "parameters" => %{
                   "TenantId" => %{"name" => "X-Tenant-Id", "in" => "header", "required" => true}
                 }
               },
               "paths" => %{
                 "/orders" => %{
                   "parameters" => [%{"$ref" => "#/components/parameters/TenantId"}],
                   "get" => %{"operationId" => "listOrders"},
                   "post" => %{"operationId" => "createOrder"}
                 }
               }
             })

  @headers ["x-tenant-id": :tenant_id]

  @layer1 "lib/test/integrations/shop.ex"
  @layer1_test "test/test/integrations/shop_test.exs"
  @external "test/test/integrations/shop_external_test.exs"

  defp gen(entry \\ [headers: @headers]) do
    files = %{"priv/specs/shop.json" => @spec_json}

    files =
      if entry == [],
        do: files,
        else: Map.put(files, ".hearth.exs", "[integrations: [shop: #{inspect(entry)}]]")

    test_project(files: files)
    |> Igniter.compose_task("hearth.gen", ["priv/specs/shop.json", "--integration", "Shop"])
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [shop: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp read(igniter, path) do
    igniter |> Igniter.include_existing_file(path) |> created_file(path)
  end

  describe "gen" do
    test "Layer 1 sends the headers, the client test checks them" do
      igniter = gen()

      layer1 = created_file(igniter, @layer1)
      assert layer1 =~ ~s|@headers ["x-tenant-id"]|
      assert layer1 =~ ~s|# x-tenant-id: the `:tenant_id` option, else config.|
      assert layer1 =~ "put_headers: &put_headers/1"

      assert created_file(igniter, @layer1_test) =~
               ~s(test "request! sets the x-tenant-id header from config" do)

      assert created_file(igniter, @external) =~ ~s/System.get_env("SHOP_TENANT_ID")/
    end

    test "wires each header's env var into runtime.exs, next to the credential" do
      runtime = gen() |> created_file("config/runtime.exs")

      assert runtime =~
               ~s/System.get_env("SHOP_TENANT_ID") || raise("missing SHOP_TENANT_ID environment variable")/

      assert runtime =~ ~s/tenant_id: System.get_env("SHOP_TENANT_ID") || "DEV_NO_SHOP_TENANT_ID"/
      assert runtime =~ "SHOP_API_KEY"
    end

    test "keeps headers in the entry; the notice names the env vars" do
      igniter = gen()

      assert entry(igniter)[:headers] == @headers
      assert notice_text(igniter) =~ "config/runtime.exs (credential, headers)"
      assert notice_text(igniter) =~ "SHOP_TENANT_ID"
    end

    test "regen is clean right after gen" do
      gen()
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", ["shop"])
      |> assert_unchanged()
    end

    test "without headers, points at the required header nothing sends" do
      igniter = gen([])

      refute created_file(igniter, @layer1) =~ "put_headers"
      assert notice_text(igniter) =~ ~s|headers: ["x-tenant-id": :tenant_id]|
    end

    test "a covered header gets no suggestion" do
      refute gen() |> notice_text() =~ "requires"
    end

    test "halts on a malformed headers: entry" do
      assert gen(headers: ["x-tenant-id": "tenant_id"]) |> issue_text() =~
               ~s|`headers:` "x-tenant-id" takes a config key|
    end

    test "halts on a config key Req already uses" do
      assert gen(headers: ["x-tenant-id": :retry]) |> issue_text() =~
               ~s|`headers:` "x-tenant-id" uses :retry, which is already a request option|
    end

    test "halts on a header the auth scheme already sends" do
      issue = gen(headers: [authorization: :token]) |> issue_text()

      assert issue =~ ~s|`headers:` for shop names "authorization", which the credential (bearer)|
      assert issue =~ "auth: [credential:"
    end
  end

  describe "regen" do
    test "headers added to the entry later: regen sends them and wires their config" do
      igniter =
        gen([])
        |> apply_igniter!()
        |> Hearth.Config.Project.put_fields(:shop, headers: @headers)
        |> apply_igniter!()

      regen = Igniter.compose_task(igniter, "hearth.regen", ["shop"])

      assert read(regen, @layer1) =~ ~s|@headers ["x-tenant-id"]|
      assert read(regen, @layer1_test) =~ "x-tenant-id"
      assert read(regen, "config/runtime.exs") =~ "SHOP_TENANT_ID"

      regen
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", ["shop"])
      |> assert_unchanged()
    end

    test "halts on a malformed headers: entry" do
      igniter =
        gen([])
        |> apply_igniter!()
        |> Hearth.Config.Project.put_fields(:shop, headers: [:tenant_id])
        |> apply_igniter!()

      assert igniter |> Igniter.compose_task("hearth.regen", ["shop"]) |> issue_text() =~
               "`headers:` maps header names"
    end

    test "halts on a header the auth scheme already sends" do
      igniter =
        gen([])
        |> apply_igniter!()
        |> Hearth.Config.Project.put_fields(:shop, headers: [authorization: :token])
        |> apply_igniter!()

      assert igniter |> Igniter.compose_task("hearth.regen", ["shop"]) |> issue_text() =~
               ~s|`headers:` for shop names "authorization", which the credential (bearer)|
    end
  end
end
