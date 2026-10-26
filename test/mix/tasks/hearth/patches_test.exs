defmodule Mix.Tasks.Hearth.PatchesTest do
  use Hearth.TaskCase, async: true

  # `overrides: [patches: …]` across gen, regen, diff and --sync. The
  # spec declares no security scheme — its operations take a required
  # `authorization` header instead — so the patch adds a bearer scheme
  # for `auth:` to wire.

  @spec_map %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "Acme", "version" => "1.0"},
    "servers" => [%{"url" => "https://api.acme.test"}],
    "paths" => %{
      "/items/{id}" => %{
        "get" => %{
          "operationId" => "getItem",
          "parameters" => [
            %{"name" => "authorization", "in" => "header", "required" => true}
          ]
        }
      }
    }
  }

  @patches %{
    "/components/securitySchemes/bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
    "/security" => [%{"bearerAuth" => []}]
  }

  @layer1 "lib/test/integrations/acme.ex"

  defp gen(patches \\ @patches, spec \\ @spec_map) do
    test_project(
      files: %{
        "priv/specs/acme.json" => JSON.encode!(spec),
        ".hearth.exs" => "[integrations: [acme: [overrides: [patches: #{inspect(patches)}]]]]"
      }
    )
    |> Igniter.compose_task("hearth.gen", ["priv/specs/acme.json", "--integration", "Acme"])
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [acme: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp pruned(igniter),
    do: igniter |> created_file("priv/hearth/acme.yaml") |> YamlElixir.read_from_string!()

  describe "gen" do
    test "a patched-in bearer scheme is wired like a declared one" do
      igniter = gen()

      assert igniter.issues == []
      assert created_file(igniter, @layer1) =~ "Bearer"
      assert created_file(igniter, "config/runtime.exs") =~ "ACME_API_KEY"
      assert entry(igniter)[:auth] == [scheme: "bearerAuth", available: [bearerAuth: "bearer"]]
    end

    test "the authorization header the scheme covers gets no headers: suggestion" do
      refute gen() |> notice_text() =~ "which nothing sends yet"
      assert gen(%{}) |> notice_text() =~ ~s|headers: [authorization: :authorization]|
    end

    test "the pruned spec carries the patch; the entry keeps it" do
      igniter = gen()

      assert pruned(igniter)["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
      assert entry(igniter)[:overrides] == [patches: @patches]
    end

    test "regen and diff are clean right after gen" do
      igniter = gen() |> apply_igniter!()

      igniter |> Igniter.compose_task("hearth.regen", ["acme"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["acme"]) |> notice_text() =~
               "no drift"
    end

    test "a patch the source already has is reported stale" do
      spec = Map.put(@spec_map, "security", [%{"bearerAuth" => []}])

      assert gen(@patches, spec) |> notice_text() =~
               ~s|patches "/security" (already in the source)|
    end

    test "halts on a patch it can't apply" do
      assert gen(%{"/info/title/x" => "y"}) |> issue_text() =~
               ~s|can't set "/info/title/x": "/info/title" is a string|
    end

    test "halts on a malformed patches: block" do
      assert gen(%{"security" => []}) |> issue_text() =~ "isn't a JSON pointer"
    end
  end

  describe "added later" do
    test "diff reports the auth change; --sync wires the credential" do
      igniter = gen(%{}) |> apply_igniter!()
      refute created_file(igniter, @layer1) =~ "Bearer"

      igniter =
        igniter
        |> Hearth.Config.Project.put_fields(:acme, overrides: [patches: @patches])
        |> apply_igniter!()

      assert igniter |> Igniter.compose_task("hearth.diff", ["acme"]) |> issue_text() =~
               "auth: none → bearer"

      synced = Igniter.compose_task(igniter, "hearth.regen", ["acme", "--sync"])
      layer1 = synced |> Igniter.include_existing_file(@layer1) |> created_file(@layer1)
      assert layer1 =~ "Bearer"

      assert synced
             |> Igniter.include_existing_file("config/runtime.exs")
             |> created_file("config/runtime.exs") =~ "ACME_API_KEY"
    end
  end
end
