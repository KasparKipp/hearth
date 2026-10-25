defmodule Mix.Tasks.Hearth.DiffTest do
  use ExUnit.Case, async: true

  import Igniter.Test, except: [diff: 1, diff: 2]

  # A small spec, varied per test. pets: listPets, createPets, showPet.
  defp spec(changes \\ []) do
    list_params =
      if changes[:limit_param],
        do: [%{"name" => "limit", "in" => "query"}],
        else: []

    pet_props =
      Map.merge(
        %{"name" => %{"type" => "string"}},
        if(changes[:pet_age], do: %{"age" => %{"type" => "integer"}}, else: %{})
      )

    list_id = changes[:list_id] || "listPets"

    paths =
      %{
        "/pets" => %{
          "get" => %{"operationId" => list_id, "tags" => ["pets"], "parameters" => list_params},
          "post" => %{"operationId" => "createPets", "tags" => ["pets"]}
        },
        "/pets/{id}" => %{
          "get" => %{
            "operationId" => "showPet",
            "tags" => ["pets"],
            "responses" => %{
              "200" => %{
                "description" => "ok",
                "content" => %{
                  "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Pet"}}
                }
              }
            }
          }
        }
      }
      |> then(fn paths ->
        if changes[:drop_show], do: Map.delete(paths, "/pets/{id}"), else: paths
      end)
      |> then(fn paths ->
        if changes[:search],
          do:
            put_in(paths["/pets/search"], %{
              "get" => %{"operationId" => "searchPets", "tags" => ["pets"]}
            }),
          else: paths
      end)

    JSON.encode!(%{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Pets", "version" => "1.0"},
      "servers" => [%{"url" => "https://api.example.com"}],
      "paths" => paths,
      "components" => %{"schemas" => %{"Pet" => %{"type" => "object", "properties" => pet_props}}}
    })
  end

  defp gen(tag_args \\ []) do
    test_project(files: %{"priv/specs/pets.json" => spec()})
    |> Igniter.compose_task(
      "hearth.gen",
      ["priv/specs/pets.json", "--integration", "Pets"] ++ tag_args
    )
    |> apply_igniter!()
  end

  defp put_source(igniter, content, path \\ "priv/specs/pets.json") do
    igniter
    |> Igniter.create_new_file(path, content, on_exists: :overwrite)
    |> apply_igniter!()
  end

  defp diff(igniter, argv \\ ["pets"]), do: Igniter.compose_task(igniter, "hearth.diff", argv)

  defp issue_text(igniter), do: Enum.join(igniter.issues, "\n\n")
  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  describe "no drift" do
    test "reports no drift and writes nothing" do
      igniter = gen() |> diff()

      assert igniter.issues == []
      assert notice_text(igniter) =~ "pets: no drift against priv/specs/pets.json"
      assert notice_text(igniter) =~ "unchanged since the last gen or sync"
      assert_unchanged(igniter)
    end
  end

  describe "drift" do
    test "an additive change is an issue listing each change" do
      igniter = gen() |> put_source(spec(limit_param: true, pet_age: true)) |> diff()

      text = issue_text(igniter)
      assert text =~ "pets has drifted from priv/specs/pets.json"
      assert text =~ "changed since the last gen or sync"
      assert text =~ "~ get /pets (listPets): query parameter limit added"
      assert text =~ "~ Pet: property age added"
      refute text =~ "[breaking]"
      assert text =~ "2 changes, none breaking"
      assert text =~ "mix hearth.regen pets --sync"
      assert_unchanged(igniter)
    end

    test "a breaking change is marked" do
      igniter = gen() |> put_source(spec(drop_show: true)) |> diff()

      assert issue_text(igniter) =~ "- get /pets/{id} (showPet)  [breaking]"
      # Pet is only reachable from showPet, so it leaves the pruned spec too.
      assert issue_text(igniter) =~ "- Pet  [breaking]"
      assert issue_text(igniter) =~ "2 changes (2 breaking)"
    end

    test "--fail-on breaking leaves additive drift as a notice" do
      igniter =
        gen()
        |> put_source(spec(limit_param: true))
        |> diff(["pets", "--fail-on", "breaking"])

      assert igniter.issues == []
      assert notice_text(igniter) =~ "query parameter limit added"
    end

    test "--fail-on breaking still fails on breaking drift" do
      igniter =
        gen() |> put_source(spec(drop_show: true)) |> diff(["pets", "--fail-on", "breaking"])

      assert issue_text(igniter) =~ "[breaking]"
    end

    test "rejects an unknown --fail-on" do
      igniter = gen() |> diff(["pets", "--fail-on", "sometimes"])

      assert issue_text(igniter) =~ "--fail-on"
    end

    test "an unsynced tags: edit shows up as drift" do
      igniter = gen(["--tag", "pets:listPets"]) |> Igniter.include_existing_file(".hearth.exs")

      exs =
        igniter
        |> then(&Rewrite.source!(&1.rewrite, ".hearth.exs"))
        |> Rewrite.Source.get(:content)
        |> String.replace(
          ~s|include: ["listPets"], exclude: ["createPets", "showPet"]|,
          ~s|include: ["listPets", "createPets"], exclude: ["showPet"]|
        )

      igniter = igniter |> put_source(exs, ".hearth.exs") |> diff()

      assert issue_text(igniter) =~ "+ post /pets (createPets)"
      assert issue_text(igniter) =~ "unchanged since the last gen or sync"
    end
  end

  describe "an upstream operationId rename" do
    test "is drift with a call-site hint, not breaking" do
      igniter = gen() |> put_source(spec(list_id: "listAllPets")) |> diff()

      text = issue_text(igniter)

      assert text =~
               "~ get /pets (listPets): renamed to listAllPets — call sites: list_pets → list_all_pets"

      refute text =~ "[breaking]"
    end

    test "under a partly selected tag is still a rename, not a removal" do
      igniter =
        gen(["--tag", "pets:listPets"]) |> put_source(spec(list_id: "listAllPets")) |> diff()

      text = issue_text(igniter)
      assert text =~ "renamed to listAllPets"
      refute text =~ "- get /pets"
      refute text =~ "not selected by `tags:`"
    end

    test "passes --fail-on breaking" do
      igniter =
        gen(["--tag", "pets:listPets"])
        |> put_source(spec(list_id: "listAllPets"))
        |> diff(["pets", "--fail-on", "breaking"])

      assert igniter.issues == []
      assert notice_text(igniter) =~ "renamed to listAllPets"
    end
  end

  describe "new upstream operations tags: doesn't select" do
    test "are listed, without failing" do
      igniter = gen(["--tag", "pets:listPets"]) |> put_source(spec(search: true)) |> diff()

      assert igniter.issues == []
      assert notice_text(igniter) =~ "not selected by `tags:`"
      assert notice_text(igniter) =~ "get /pets/search (searchPets)"
    end

    test "under an :all tag they are drift" do
      igniter = gen() |> put_source(spec(search: true)) |> diff()

      assert issue_text(igniter) =~ "+ get /pets/search (searchPets)"
    end
  end

  describe "--source" do
    test "compares against another spec, leaving .hearth.exs alone" do
      igniter =
        gen()
        |> put_source(spec(pet_age: true), "priv/specs/pets-v2.json")
        |> diff(["pets", "--source", "priv/specs/pets-v2.json"])

      text = issue_text(igniter)
      assert text =~ "pets has drifted from priv/specs/pets-v2.json"
      assert text =~ "~ Pet: property age added"
      assert text =~ "point `source:` at priv/specs/pets-v2.json"
      assert text =~ "differs from the source recorded at the last gen or sync"
      assert_unchanged(igniter)
    end

    test "needs exactly one integration" do
      igniter = gen() |> diff(["--all", "--source", "priv/specs/pets-v2.json"])

      assert issue_text(igniter) =~ "--source"
    end
  end

  describe "halts" do
    test "when nothing is named" do
      assert gen() |> diff([]) |> issue_text() =~ "mix hearth.diff stripe"
    end

    test "when the source can't be read" do
      igniter = gen() |> diff(["pets", "--source", "priv/specs/gone.json"])

      assert issue_text(igniter) =~ "priv/specs/gone.json"
      assert issue_text(igniter) =~ "not found"
    end

    test "when the pruned spec is missing" do
      igniter =
        gen()
        |> Igniter.rm("priv/hearth/pets.yaml")
        |> apply_igniter!()
        |> diff()

      assert issue_text(igniter) =~ "priv/hearth/pets.yaml"
      assert issue_text(igniter) =~ "mix hearth.regen pets --sync"
    end
  end
end
