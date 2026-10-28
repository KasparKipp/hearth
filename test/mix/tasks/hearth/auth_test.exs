defmodule Mix.Tasks.Hearth.AuthTest do
  use Hearth.TaskCase, async: true

  # Choosing the auth scheme: gen records the spec's schemes in the
  # `.hearth.exs` entry as `auth: [scheme: …, available: […]]`, and `scheme:` is
  # the one Layer 1 wires. The spec is Stripe-like: HTTP basic listed
  # first, bearer second.

  @spec_json JSON.encode!(%{
               "openapi" => "3.0.0",
               "info" => %{"title" => "Pay", "version" => "1"},
               "servers" => [%{"url" => "https://api.pay.test"}],
               "security" => [%{"basicAuth" => []}, %{"bearerAuth" => []}],
               "paths" => %{"/v1/charges" => %{"get" => %{"operationId" => "GetCharges"}}},
               "components" => %{
                 "securitySchemes" => %{
                   "basicAuth" => %{"type" => "http", "scheme" => "basic"},
                   "bearerAuth" => %{"type" => "http", "scheme" => "bearer"}
                 }
               }
             })

  @layer1 "lib/test/integrations/pay.ex"

  defp gen(exs \\ nil) do
    files = %{"priv/specs/pay.json" => @spec_json}
    files = if exs, do: Map.put(files, ".hearth.exs", exs), else: files

    test_project(files: files)
    |> Igniter.compose_task("hearth.gen", ["priv/specs/pay.json", "--integration", "Pay"])
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [pay: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp set_scheme(igniter, scheme) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")

    exs =
      igniter
      |> created_file(".hearth.exs")
      |> String.replace(~r/scheme: "\w+"/, "scheme: #{inspect(scheme)}")

    igniter
    |> Igniter.create_new_file(".hearth.exs", exs, on_exists: :overwrite)
    |> apply_igniter!()
  end

  describe "gen" do
    test "records every scheme and wires bearer over basic, though basic comes first" do
      igniter = gen()

      assert entry(igniter)[:auth] == [
               scheme: "bearerAuth",
               available: [basicAuth: "basic", bearerAuth: "bearer"]
             ]

      assert created_file(igniter, @layer1) =~ "Bearer"
      assert created_file(igniter, "config/runtime.exs") =~ "PAY_API_KEY"
      assert notice_text(igniter) =~ "Set the credential: the PAY_API_KEY environment variable"
    end

    test "a `scheme:` written before gen is respected" do
      igniter = gen(~s|[integrations: [pay: [auth: [scheme: "basicAuth"]]]]|)

      assert entry(igniter)[:auth][:scheme] == "basicAuth"
      assert created_file(igniter, @layer1) =~ ~s|"Basic " <> Base.encode64(credential(request))|
      assert notice_text(igniter) =~ "Set the credential (`user:password`)"
    end

    test "halts on a scheme the spec doesn't have, listing the ones it does" do
      igniter = gen(~s|[integrations: [pay: [auth: [scheme: "oauth"]]]]|)

      assert issue_text(igniter) =~ ~s|chooses an auth scheme the spec doesn't have: "oauth"|
      assert issue_text(igniter) =~ "basicAuth, bearerAuth"
    end

    test "a spec without security schemes records no auth" do
      spec = JSON.decode!(@spec_json) |> Map.delete("security") |> Map.delete("components")

      igniter =
        test_project(files: %{"priv/specs/pay.json" => JSON.encode!(spec)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/pay.json", "--integration", "Pay"])

      refute Keyword.has_key?(entry(igniter), :auth)
    end
  end

  describe "switching with --sync" do
    defp generated,
      do: gen(~s|[integrations: [pay: [auth: [scheme: "basicAuth"]]]]|) |> apply_igniter!()

    test "plain regen halts when `scheme:` changed, pointing at --sync" do
      igniter =
        generated() |> set_scheme("bearerAuth") |> Igniter.compose_task("hearth.regen", ["pay"])

      assert issue_text(igniter) =~ ~s|`auth: [scheme: "bearerAuth"]`|
      assert issue_text(igniter) =~ "mix hearth.regen pay --sync"
    end

    test "diff reports the switch; --sync wires it and the credential" do
      igniter = generated() |> set_scheme("bearerAuth")

      assert igniter |> Igniter.compose_task("hearth.diff", ["pay"]) |> issue_text() =~
               "~ auth: basic → bearer  [breaking]"

      synced = Igniter.compose_task(igniter, "hearth.regen", ["pay", "--sync"])

      assert created_file(synced, @layer1) =~ "Bearer"
      assert created_file(synced, "config/runtime.exs") =~ "PAY_API_KEY"
      assert entry(synced)[:auth][:scheme] == "bearerAuth"
    end

    test "--sync from no auth to bearer seeds the credential in the external test" do
      unsecured = JSON.decode!(@spec_json) |> Map.delete("security") |> Map.delete("components")
      external = "test/test/integrations/pay_external_test.exs"

      generated =
        test_project(files: %{"priv/specs/pay.json" => JSON.encode!(unsecured)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/pay.json", "--integration", "Pay"])
        |> apply_igniter!()

      refute created_file(generated, external) =~ "PAY_API_KEY"

      synced =
        generated
        |> Igniter.create_new_file("priv/specs/pay.json", @spec_json, on_exists: :overwrite)
        |> Hearth.Config.Project.put_fields(:pay, auth: [scheme: "bearerAuth"])
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.regen", ["pay", "--sync"])

      content = created_file(synced, external)
      assert content =~ ~s|api_key: System.get_env("PAY_API_KEY") \|\| "DEV_NO_PAY_API_KEY"|
      assert content =~ "async: false"
      assert notice_text(synced) =~ "Added a setup block seeding PAY_API_KEY to #{external}"

      synced
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", ["pay"])
      |> assert_unchanged()
    end

    test "regen and diff are clean right after gen" do
      igniter = gen() |> apply_igniter!()

      igniter |> Igniter.compose_task("hearth.regen", ["pay"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["pay"]) |> notice_text() =~
               "no drift"
    end

    test "--sync halts on a scheme the spec doesn't have" do
      igniter =
        generated()
        |> set_scheme("oauth")
        |> Igniter.compose_task("hearth.regen", ["pay", "--sync"])

      assert issue_text(igniter) =~ ~s|chooses an auth scheme the spec doesn't have: "oauth"|
    end
  end
end
