defmodule Mix.Tasks.Hearth.ValuesTest do
  use Hearth.TaskCase, async: true

  # Where the credential, the headers and the base URL come from — the
  # entry's `auth: [credential:]`, `headers:` and `base_url:` — across gen
  # and regen. The spec has no servers and a bearer scheme; every
  # operation requires two headers.

  @spec_json JSON.encode!(%{
               "openapi" => "3.0.0",
               "info" => %{"title" => "Kiosk", "version" => "1"},
               "security" => [%{"bearerAuth" => []}],
               "components" => %{
                 "securitySchemes" => %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}}
               },
               "paths" => %{
                 "/orders" => %{"get" => %{"operationId" => "listOrders"}}
               }
             })

  @entry [
    auth: [credential: [resolve: {Test.Tenancy, :token}, options: [:tenant]]],
    headers: ["x-app-key": :app_key, "x-tenant-id": [option: :tenant_id]],
    base_url: [resolve: {Test.Tenancy, :gateway}, options: [:tenant]]
  ]

  @layer1 "lib/test/integrations/kiosk.ex"
  @layer1_test "test/test/integrations/kiosk_test.exs"
  @external "test/test/integrations/kiosk_external_test.exs"

  defp gen(entry \\ @entry) do
    test_project(
      files: %{
        "priv/specs/kiosk.json" => @spec_json,
        ".hearth.exs" => "[integrations: [kiosk: #{inspect(entry)}]]"
      }
    )
    |> Igniter.compose_task("hearth.gen", ["priv/specs/kiosk.json", "--integration", "Kiosk"])
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [kiosk: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp read(igniter, path) do
    igniter |> Igniter.include_existing_file(path) |> created_file(path)
  end

  describe "gen" do
    test "runtime.exs gets only the values read from config" do
      igniter = gen()
      assert igniter.issues == []

      runtime = created_file(igniter, "config/runtime.exs")
      assert runtime =~ ~s/System.get_env("KIOSK_APP_KEY")/
      refute runtime =~ "KIOSK_API_KEY"
      refute runtime =~ "KIOSK_TENANT_ID"
      refute runtime =~ "KIOSK_BASE_URL"
    end

    test "keeps credential:, headers: and base_url: in the entry" do
      entry = entry(gen())

      assert entry[:auth][:scheme] == "bearerAuth"
      assert entry[:auth][:credential] == @entry[:auth][:credential]
      assert entry[:headers] == @entry[:headers]
      assert entry[:base_url] == @entry[:base_url]
    end

    test "the notice says where each value comes from; no placeholder warning" do
      igniter = gen()
      notice = notice_text(igniter)

      assert notice =~ "The credential comes from Test.Tenancy.token/1"
      assert notice =~ "KIOSK_APP_KEY"
      assert notice =~ "Pass `tenant_id:` (x-tenant-id) on every call."
      assert notice =~ "The base URL comes from Test.Tenancy.gateway/1"
      refute Enum.join(igniter.warnings, "\n") =~ "placeholder"
    end

    test "the client test passes per-call values; the scaffold reads them from env" do
      igniter = gen()

      client_test = created_file(igniter, @layer1_test)
      assert client_test =~ ~s|@opts [api_key: @api_key, tenant_id: "hearth-test-tenant_id"|
      assert client_test =~ ~s|test "without tenant_id:, request! raises" do|
      assert client_test =~ "Test.Tenancy.token/1 resolves the credential"

      external = created_file(igniter, @external)
      assert external =~ ~s/tenant_id: System.get_env("KIOSK_TENANT_ID")/
      assert external =~ "KioskApi.Req.list_orders(opts())"
    end

    test "the generated layers compile cleanly" do
      igniter = gen()

      sources =
        Enum.map(
          [
            @layer1,
            "lib/test/integrations/kiosk/kiosk_api.ex",
            "lib/test/integrations/kiosk/kiosk_api/req.ex"
          ],
          &created_file(igniter, &1)
        )

      tenancy = """
      defmodule Test.Tenancy do
        def token(_opts), do: "t"
        def gateway(_opts), do: "https://gw.test"
      end
      """

      {_modules, diagnostics} =
        Code.with_diagnostics(fn ->
          Enum.flat_map([tenancy | sources], &Code.compile_string/1)
        end)

      assert diagnostics == []
    end

    test "regen is clean right after gen" do
      gen()
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", ["kiosk"])
      |> assert_unchanged()
    end

    test "base_url: :base_url wires KIOSK_BASE_URL, with no dev placeholder" do
      runtime = gen(base_url: :base_url) |> created_file("config/runtime.exs")

      assert runtime =~
               ~s/System.get_env("KIOSK_BASE_URL") || raise("missing KIOSK_BASE_URL environment variable")/

      assert runtime =~ ~r/base_url: System.get_env\("KIOSK_BASE_URL"\)\n/
    end

    test "a malformed value halts, naming it" do
      assert gen(base_url: "https://x.test") |> issue_text() =~
               "`base_url:` for kiosk — expected a config key"
    end
  end

  describe "regen" do
    test "--sync keeps credential:, so the regen after it is a no-op" do
      synced =
        gen()
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.regen", ["kiosk", "--sync"])
        |> apply_igniter!()

      assert entry(synced)[:auth][:credential] == @entry[:auth][:credential]
      assert entry(synced)[:auth][:scheme] == "bearerAuth"

      synced
      |> Igniter.compose_task("hearth.regen", ["kiosk"])
      |> assert_unchanged()
    end

    test "a value that moved off config: its runtime.exs line is named for deletion" do
      igniter =
        gen(headers: ["x-tenant-id": :tenant_id])
        |> apply_igniter!()
        |> Hearth.Config.Project.put_fields(:kiosk,
          headers: ["x-tenant-id": [option: :tenant_id]]
        )
        |> apply_igniter!()

      regen = Igniter.compose_task(igniter, "hearth.regen", ["kiosk"])

      assert read(regen, @layer1) =~ "# x-tenant-id: the `:tenant_id` option."
      assert notice_text(regen) =~ "config/runtime.exs still reads KIOSK_TENANT_ID"
    end
  end
end
