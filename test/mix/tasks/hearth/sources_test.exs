defmodule Mix.Tasks.Hearth.SourcesTest do
  use Hearth.TaskCase, async: true

  # `sources:` — one integration from several specs of one API: two
  # base paths behind one host, a schema name both define differently. gen reads the sources from the
  # entry written before it.

  defp spec(title, base, path, id, schema_props) do
    JSON.encode!(%{
      "openapi" => "3.0.3",
      "info" => %{"title" => title, "version" => "1.0"},
      "servers" => [%{"url" => base}],
      "paths" => %{
        path => %{
          "get" => %{
            "operationId" => id,
            "tags" => [title],
            "responses" => %{
              "200" => %{
                "description" => "OK",
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/address"}
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{"address" => %{"type" => "object", "properties" => schema_props}}
      }
    })
  end

  defp items,
    do: spec("Items", "/items/v1", "/items/{id}", "getItem", %{"street" => %{"type" => "string"}})

  defp orders,
    do:
      spec("Orders", "/orders/v1", "/orders/{id}", "getOrder", %{"city" => %{"type" => "string"}})

  @sources [items: "priv/specs/items.json", orders: "priv/specs/orders.json"]

  @api "lib/test/integrations/kit/kit_api.ex"
  @layer3 "lib/test/integrations/kit/kit_api/req.ex"

  defp gen(entry \\ [sources: @sources], args \\ ["--integration", "Kit"]) do
    test_project(
      files: %{
        "priv/specs/items.json" => items(),
        "priv/specs/orders.json" => orders(),
        ".hearth.exs" => "[integrations: [kit: #{inspect(entry)}]]"
      }
    )
    |> Igniter.compose_task("hearth.gen", args)
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [kit: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  describe "gen" do
    test "one behaviour with every source's operations" do
      igniter = gen()

      assert igniter.issues == []
      api = created_file(igniter, @api)
      assert api =~ "def get_item(id, opts"
      assert api =~ "def get_order(id, opts"

      layer3 = created_file(igniter, @layer3)
      assert layer3 =~ ~s|Kit.request("/items/v1/items/\#{id}", opts)|
      assert layer3 =~ ~s|Kit.request("/orders/v1/orders/\#{id}", opts)|
    end

    test "the pruned spec is the merge; differing components carry their source" do
      pruned = gen() |> created_file("priv/hearth/kit.yaml") |> YamlElixir.read_from_string!()

      assert Map.keys(pruned["components"]["schemas"]) |> Enum.sort() ==
               ["items_address", "orders_address"]

      assert pruned["info"]["title"] == "Items + Orders"
    end

    test "keeps sources: and records a checksum per source" do
      entry = entry(gen())

      assert entry[:sources] == @sources
      refute Keyword.has_key?(entry, :source)

      assert [items: <<_::binary-size(64)>>, orders: <<_::binary-size(64)>>] =
               entry[:source_sha256]
    end

    test "Layer 2's footer names every source" do
      assert created_file(gen(), @api) =~
               "items: priv/specs/items.json, orders: priv/specs/orders.json"
    end

    test "a source that doesn't load halts, naming it" do
      sources = Keyword.put(@sources, :orders, "priv/specs/nope.json")

      assert gen(sources: sources) |> issue_text() =~ ~s|file not found at "priv/specs/nope.json"|
    end

    test "a malformed sources: halts" do
      assert gen(sources: ["priv/specs/items.json"]) |> issue_text() =~ "`sources:`"
    end

    test "without a source argument or entry sources, asks for a source" do
      assert gen([]) |> issue_text() =~ "source"
    end
  end

  describe "regen, diff and --sync" do
    defp generated, do: gen() |> apply_igniter!()

    defp upstream_change(igniter) do
      changed =
        spec("Orders", "/orders/v1", "/orders/{id}", "getOrder", %{
          "city" => %{"type" => "string"},
          "zip" => %{"type" => "string"}
        })

      igniter
      |> Igniter.create_new_file("priv/specs/orders.json", changed, on_exists: :overwrite)
      |> apply_igniter!()
    end

    test "regen and diff are clean right after gen" do
      igniter = generated()

      igniter |> Igniter.compose_task("hearth.regen", ["kit"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["kit"]) |> notice_text() =~
               "no drift"
    end

    test "diff reports a change in one source and names it; --sync applies it" do
      igniter = upstream_change(generated())

      report = igniter |> Igniter.compose_task("hearth.diff", ["kit"]) |> issue_text()
      assert report =~ "orders_address: property zip added"
      assert report =~ "orders changed since the last gen or sync"

      synced =
        igniter |> Igniter.compose_task("hearth.regen", ["kit", "--sync"]) |> apply_igniter!()

      assert synced |> Igniter.compose_task("hearth.diff", ["kit"]) |> notice_text() =~
               "no drift"
    end

    # Both sources define `deadline` identically, so it starts shared;
    # then orders changes its copy.
    defp deadline(props), do: %{"type" => "object", "properties" => props}

    defp with_deadline(json, deadline) do
      json
      |> JSON.decode!()
      |> put_in(["components", "schemas", "deadline"], deadline)
      |> put_in(
        ["components", "schemas", "address", "properties", "due"],
        %{"$ref" => "#/components/schemas/deadline"}
      )
      |> JSON.encode!()
    end

    defp gen_shared(entry) do
      shared = deadline(%{"at" => %{"type" => "string"}})

      test_project(
        files: %{
          "priv/specs/items.json" => with_deadline(items(), shared),
          "priv/specs/orders.json" => with_deadline(orders(), shared),
          ".hearth.exs" => "[integrations: [kit: #{inspect(entry)}]]"
        }
      )
      |> Igniter.compose_task("hearth.gen", ["--integration", "Kit"])
      |> apply_igniter!()
      |> Igniter.create_new_file(
        "priv/specs/orders.json",
        with_deadline(
          orders(),
          deadline(%{"at" => %{"type" => "string"}, "tz" => %{"type" => "string"}})
        ),
        on_exists: :overwrite
      )
      |> apply_igniter!()
    end

    test "a shared component that splits makes diff warn and suggest shared:" do
      igniter = gen_shared(sources: @sources)

      assert igniter
             |> created_file("priv/hearth/kit.yaml")
             |> YamlElixir.read_from_string!()
             |> get_in(["components", "schemas", "deadline"])

      report = igniter |> Igniter.compose_task("hearth.diff", ["kit"]) |> issue_text()

      assert report =~ "deadline is no longer the same in every source"
      assert report =~ ~s|overrides: [shared: %{"schemas/deadline" => :items}]|

      synced = Igniter.compose_task(igniter, "hearth.regen", ["kit", "--sync"])
      assert Enum.join(synced.warnings, "\n") =~ ~s|"schemas/deadline" => :items|
    end

    test "the suggested keeper is the source whose copy still matches, docs aside" do
      described = &Map.put(deadline(%{"at" => %{"type" => "string"}}), "description", &1)

      igniter =
        test_project(
          files: %{
            "priv/specs/items.json" => with_deadline(items(), described.("Item deadline.")),
            "priv/specs/orders.json" => with_deadline(orders(), described.("Order deadline.")),
            ".hearth.exs" => "[integrations: [kit: #{inspect(sources: @sources)}]]"
          }
        )
        |> Igniter.compose_task("hearth.gen", ["--integration", "Kit"])
        |> apply_igniter!()
        |> Igniter.create_new_file(
          "priv/specs/items.json",
          with_deadline(items(), deadline(%{"at" => %{"type" => "integer"}})),
          on_exists: :overwrite
        )
        |> apply_igniter!()

      report = igniter |> Igniter.compose_task("hearth.diff", ["kit"]) |> issue_text()
      assert report =~ ~s|overrides: [shared: %{"schemas/deadline" => :orders}]|
    end

    test "with shared:, the plain name stays with that source; no warning" do
      entry = [sources: @sources, overrides: [shared: %{"schemas/deadline" => :items}]]
      diff = entry |> gen_shared() |> Igniter.compose_task("hearth.diff", ["kit"])

      report = issue_text(diff)
      refute report =~ "no longer the same"
      assert report =~ "+ orders_deadline"
      refute report =~ "- deadline"
      refute report =~ "items_deadline"
    end

    test "diff --source refuses an integration with sources:" do
      igniter = generated()

      assert igniter
             |> Igniter.compose_task("hearth.diff", ["kit", "--source", "priv/specs/items.json"])
             |> issue_text() =~ "`--source` can't stand in for `sources:`"
    end
  end
end
