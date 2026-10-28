defmodule Hearth.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Hearth.Config.Schema

  defp entry(fields), do: [integrations: [kit: fields]]

  # The error message for `term`, which must not validate.
  defp error(term) do
    assert {:error, message} = Schema.validate(term), inspect(term)
    assert message =~ ".hearth.exs", message
    message
  end

  describe "validate/1 accepts" do
    test "every .hearth.exs gen writes, and the examples' hand-written ones" do
      paths =
        Path.wildcard("test/generated/*/.hearth.exs.golden", match_dot: true) ++
          Path.wildcard("examples/*/.hearth.exs", match_dot: true)

      assert length(paths) >= 6

      for path <- paths do
        {term, _binding} = path |> File.read!() |> Code.eval_string()
        assert Schema.validate(term) == :ok, path
      end
    end

    test "an empty file and an empty entry" do
      assert Schema.validate([]) == :ok
      assert Schema.validate(integrations: []) == :ok
      assert Schema.validate(entry([])) == :ok
    end

    test "every value form" do
      assert Schema.validate(
               entry(
                 auth: [scheme: nil, credential: :token],
                 headers: [
                   "X-App-Key": :app_key,
                   "x-tenant-id": [option: :tenant_id],
                   "x-region": [resolve: {MyApp.Tenancy, :region}, options: [:tenant]]
                 ],
                 base_url: [option: :base_url]
               )
             ) == :ok
    end

    test "sources:, with a checksum per source" do
      assert Schema.validate(
               entry(sources: [a: "a.json", b: "b@1"], source_sha256: [a: "1", b: "2"])
             ) == :ok
    end

    test "prefixed_ids: without functions:" do
      assert Schema.validate(entry(prefixed_ids: [prefixes: [cus: "GetCustomer"]])) == :ok
    end

    test "overrides: of every kind" do
      overrides = [
        patches: %{"/security" => [%{"bearerAuth" => []}], "/x" => nil, "/n" => [1, 2.5, true]},
        tags: [Customers: ["/v1/customers*"]],
        operation_ids: %{"GetCustomers" => "ListCustomers"},
        shared: %{"schemas/address" => :items}
      ]

      assert Schema.validate(entry(overrides: overrides)) == :ok
    end
  end

  describe "validate/1 rejects the file's shape" do
    test "an unknown top-level key, listing the supported ones" do
      message = error(integratons: [])
      assert message =~ "`integratons:`"
      assert message =~ "`integrations:`, `registry:`"
    end

    test "a key given twice, at any level" do
      assert error(integrations: [], integrations: []) =~
               "the file gives `integrations:` more than once"

      assert error(entry(module: Foo.Bar, module: Foo.Baz)) =~
               "the entry for kit gives `module:` more than once"
    end

    test "integrations: that isn't a keyword list of keyword lists" do
      assert error(integrations: :oops) =~ "`integrations:`"
      assert error(integrations: [kit: :oops]) =~ "the entry for kit"
    end

    test "a malformed registry, with an example" do
      for registry <- [
            [acme: "x"],
            %{"acme" => "https://x"},
            %{"acme" => %{"1" => :url}},
            %{"acme" => %{"1" => {:alias, :two}}},
            %{"bad name!" => %{"1" => "x.json"}}
          ] do
        message = error(registry: registry)
        assert message =~ "`registry:`", message
        assert message =~ ~s|e.g. `registry: %{"acme_api"|, message
      end
    end

    test "a bad registry version names its shortcut and version, not the whole map" do
      message = error(registry: %{"acme" => %{"1" => 5}, "other" => %{"2" => "o.json"}})
      assert message =~ ~s|"acme" "1": expected a URL, a file path or {:alias, "version"}, got: 5|
      refute message =~ "o.json"
    end
  end

  describe "validate/1 rejects an entry's" do
    test "unknown keys, naming the entry and listing the supported ones" do
      message = error(entry(prefix_ids: [prefixes: [cus: "X"]]))
      assert message =~ "the entry for kit"
      assert message =~ "`prefix_ids:`"
      assert message =~ "`prefixed_ids:`"
    end

    test "module: that isn't a module alias" do
      for module <- ["MyApp.Integrations.Kit", :kit] do
        message = error(entry(module: module))
        assert message =~ "`module:` for kit"
        assert message =~ inspect(module)
      end
    end

    test "malformed sources:" do
      for sources <- [["a.json"], [a: :b], [], "a.json"] do
        message = error(entry(sources: sources))
        assert message =~ ~r/`sources:.*` for kit/, message
      end
    end

    test "malformed tags: and untagged:" do
      for tags <- [:all, [pets: :some], [pets: [include: "listPets"]], [pets: [only: []]]] do
        message = error(entry(tags: tags))
        assert message =~ "`tags:", message
        assert message =~ "`:all`, `:none`, or `[include: [...], exclude: [...]]`", message
      end

      assert error(entry(untagged: :maybe)) =~ "`untagged:` for kit"
    end

    test "malformed overrides:" do
      for {overrides, named} <- [
            {:nope, "`overrides:`"},
            {[schemas: []], "`schemas:`"},
            {[tags: [Customers: "/v1/customers*"]], "`overrides: [tags: "},
            {[operation_ids: [GetCustomers: "X"]], "`overrides: [operation_ids: …]`"},
            {[operation_ids: %{"GetCustomers" => :x}], "`overrides: [operation_ids: …]`"},
            {[shared: %{"address" => :items}], "`overrides: [shared: …]`"},
            {[shared: %{"schemas/address" => "items"}], "`overrides: [shared: …]`"}
          ] do
        message = error(entry(overrides: overrides))
        assert message =~ named, message
      end
    end

    test "unknown override kinds list the supported ones" do
      message = error(entry(overrides: [schemas: []]))
      assert message =~ "`patches:`"
      assert message =~ "`operation_ids:`"
    end

    test "malformed patches" do
      message = error(entry(overrides: [patches: %{"components" => %{}}]))
      assert message =~ ~s|"components"|
      assert message =~ "JSON pointer"

      assert error(entry(overrides: [patches: %{"" => %{}}])) =~ "JSON pointer"
      assert error(entry(overrides: [patches: [{"/security", []}]])) =~ "maps JSON pointers"

      message = error(entry(overrides: [patches: %{"/components" => %{type: "http"}}]))
      assert message =~ ~s|"/components"|
      assert message =~ "string keys"

      assert error(entry(overrides: [patches: %{"/x" => :bearer}])) =~ "JSON"
    end

    test "malformed value forms, naming the value" do
      for {fields, named} <- [
            {[auth: [credential: "token"]], "`auth: [credential: …]`"},
            {[auth: [credential: [optoin: :token]]], "`auth: [credential: …]`"},
            {[auth: [credential: [resolve: Tenancy]]], "`auth: [credential: …]`"},
            {[auth: [credential: [resolve: {"M", :f}]]], "`auth: [credential: …]`"},
            {[auth: [credential: [option: :token, resolve: {M, :f}]]], "`auth: [credential: …]`"},
            {[auth: [credential: nil]], "`auth: [credential: …]`"},
            {[base_url: "https://x.test"], "`base_url:`"},
            {[headers: ["x-a": "a"]], ~s|"x-a"|},
            {[headers: ["x-a": [option: "a"]]], ~s|"x-a"|},
            {[headers: ["x-a": :"Not Valid"]], ~s|"x-a"|},
            {[headers: ["bad header!": :key]], "HTTP header name"},
            {[headers: :nope], "`headers:`"}
          ] do
        message = error(entry(fields))
        assert message =~ named, message
      end

      assert error(entry(base_url: "https://x.test")) =~
               "a config key (`:app_key`), `[option: :app_key]` or `[resolve:"
    end

    test "malformed auth:" do
      assert error(entry(auth: :bearer)) =~ "`auth:` for kit"
      assert error(entry(auth: [scheme: :bearer])) =~ "`auth: [scheme: …]`"
      assert error(entry(auth: [schema: "bearer"])) =~ "`schema:`"
    end

    test "malformed prefixed_ids:" do
      for bad <- [
            :nope,
            [prefixes: [cus: :GetCustomersCustomer]],
            [prefixes: []],
            [functions: [retrieve: :get]],
            [functions: [retrieve: :fetch], prefixes: [cus: "X"]],
            [functions: [{:"Not Valid", :get}], prefixes: [cus: "X"]],
            [functions: [], prefixes: [cus: "X"]],
            [other: 1, prefixes: [cus: "X"]]
          ] do
        message = error(entry(prefixed_ids: bad))
        assert message =~ "prefixed_ids:", message
      end

      assert error(entry(prefixed_ids: [functions: [retrieve: :fetch], prefixes: [cus: "X"]])) =~
               ":get, :post, :put, :patch, :delete"
    end

    test "values that take one of several forms say which, with a hint" do
      message = error(entry(source_sha256: 5))
      assert message =~ "`source_sha256:` for kit — got: 5"
      assert message =~ "Delete it rather than edit it"

      message = error(entry(auth: [scheme: 5]))
      assert message =~ "`auth: [scheme: …]` for kit — got: 5"
      assert message =~ ~s|as a string, e.g. `scheme: "bearerAuth"`|

      assert error(entry(base_url: "https://x.test")) =~ "not the URL itself"
    end

    test "values that share a key or take a Req option name, naming the entry" do
      message = error(entry(headers: ["x-a": :same, "x-b": [option: :same]]))
      assert message =~ "the entry for kit — "
      assert message =~ "use the same key :same"

      assert error(entry(auth: [credential: :retry])) =~ "already a request option"
      assert error(entry(base_url: :gateway)) =~ "its key must be `:base_url`"
    end

    test "scalars of the wrong type" do
      assert error(entry(source: :stripe)) =~ "`source:` for kit"
      assert error(entry(base_path: :v1)) =~ "`base_path:` for kit"
      assert error(entry(source_sha256: 1)) =~ "`source_sha256:` for kit"
    end
  end
end
