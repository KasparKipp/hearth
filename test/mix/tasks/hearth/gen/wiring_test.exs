defmodule Mix.Tasks.Hearth.Gen.WiringTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: host-project wiring, the pruned spec, and create-only.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  # A consumer `mix.exs` with the given deps, Phoenix-style
  # `elixirc_paths` unless `elixirc_paths?: false`.
  defp mix_exs(opts) do
    {paths, clauses} =
      if Keyword.get(opts, :elixirc_paths?, true) do
        {"\n      elixirc_paths: elixirc_paths(Mix.env()),",
         """

           defp elixirc_paths(:test), do: ["lib", "test/support"]
           defp elixirc_paths(_), do: ["lib"]
         """}
      else
        {"", ""}
      end

    """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [
          app: :test,
          version: "0.1.0",#{paths}
          deps: deps()
        ]
      end
    #{clauses}
      defp deps do
        [#{Keyword.fetch!(opts, :deps)}]
      end
    end
    """
  end

  describe "host wiring — Mox mock" do
    @keyed_spec JSON.encode!(%{
                  "openapi" => "3.0.0",
                  "info" => %{"title" => "Keyed", "version" => "1.0"},
                  "servers" => [%{"url" => "https://keyed.example.com"}],
                  "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping", "tags" => ["X"]}}},
                  "components" => %{
                    "securitySchemes" => %{
                      "ApiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
                    }
                  }
                })

    defp gen(igniter, source, integration) do
      Igniter.compose_task(igniter, "hearth.gen", [source, "--integration", integration])
    end

    test "creates test/support/mocks.ex with a Mox.defmock per integration" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      source = created_file(igniter, "test/support/mocks.ex")
      assert source =~ "Mox.defmock(Test.Integrations.Petstore.PetstoreApi.Mock,"
      assert source =~ "for: Test.Integrations.Petstore.PetstoreApi"
    end

    test "adds {:mox, …, only: :test} to the consumer's deps" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      mix_exs = created_file(igniter, "mix.exs")
      assert mix_exs =~ ":mox"
      assert mix_exs =~ "only: [:test]" or mix_exs =~ "only: :test"
    end

    test "adds {:req, \"~> 0.7\"} to the consumer's deps" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      assert created_file(igniter, "mix.exs") =~ ~s|{:req, "~> 0.7"}|
    end

    test "queues `mix deps.get` when it added deps to mix.exs" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      assert {"deps.get", []} in igniter.tasks
    end

    # A `mix new` project doesn't compile test/support — without this
    # the generated Mox mock never exists in the test env.
    test "adds test/support to elixirc_paths(:test) in a plain project" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> gen("priv/specs/petstore.yaml", "Petstore")

      mix_exs = created_file(igniter, "mix.exs")
      assert mix_exs =~ "elixirc_paths: elixirc_paths(Mix.env())"

      assert mix_exs =~
               ~r/defp elixirc_paths\(:test\),\s+do: elixirc_paths\(:dev\) \+\+ \["test\/support"\]/

      assert mix_exs =~ ~r/defp elixirc_paths\(_\),\s+do: \["lib"\]/
      assert notice_text(igniter) =~ "mix.exs (test/support in elixirc_paths)"
    end

    test "leaves an existing elixirc_paths alone (e.g. a Phoenix app)" do
      test_project(
        files: %{
          "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
          "mix.exs" => mix_exs(deps: ~s|{:req, "~> 0.7"}, {:mox, "~> 1.0", only: [:test]}|)
        }
      )
      |> gen("priv/specs/petstore.yaml", "Petstore")
      |> assert_unchanged("mix.exs")
    end

    test "doesn't queue `mix deps.get` when only elixirc_paths changed" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "mix.exs" =>
              mix_exs(
                deps: ~s|{:req, "~> 0.7"}, {:mox, "~> 1.0", only: [:test]}|,
                elixirc_paths?: false
              )
          }
        )
        |> gen("priv/specs/petstore.yaml", "Petstore")

      assert created_file(igniter, "mix.exs") =~ "elixirc_paths"
      refute {"deps.get", []} in igniter.tasks
    end

    test "a second integration appends without clobbering the first" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "priv/specs/keyed.json" => @keyed_spec
          }
        )
        |> gen("priv/specs/petstore.yaml", "Petstore")
        |> gen("priv/specs/keyed.json", "Keyed")

      source = created_file(igniter, "test/support/mocks.ex")
      assert source =~ "Test.Integrations.Petstore.PetstoreApi.Mock"
      assert source =~ "Test.Integrations.Keyed.KeyedApi.Mock"
    end
  end

  describe "host wiring — config" do
    test "config/test.exs points the dispatcher at the Mox mock" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, "config/test.exs")
      assert source =~ "Test.Integrations.Petstore.PetstoreApi"
      assert source =~ "impl: Test.Integrations.Petstore.PetstoreApi.Mock"
    end

    test "writes no :hearth_domains config" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      refute created_file(igniter, "config/config.exs") =~ "hearth_domains"
    end

    test "an API-key spec wires a runtime.exs credential for prod and dev" do
      igniter =
        test_project(files: %{"priv/specs/keyed.json" => @keyed_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/keyed.json",
          "--integration",
          "Keyed"
        ])

      source = created_file(igniter, "config/runtime.exs")
      assert source =~ ~s|System.get_env("KEYED_API_KEY")|
      assert source =~ "config_env() == :prod"
      assert source =~ "config_env() == :dev"
      assert source =~ "DEV_NO_KEYED_API_KEY"
    end

    test "a :none-auth spec leaves config/runtime.exs untouched" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      refute Igniter.exists?(igniter, "config/runtime.exs")
    end

    test "leaves an existing :hearth_domains entry alone" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "config/config.exs" => "import Config\n\nconfig :test, hearth_domains: [Other.Api]\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      source = created_file(igniter, "config/config.exs")
      assert source =~ "hearth_domains: [Other.Api]"
      refute source =~ "PetstoreApi"
    end
  end

  describe "pruned spec artifact" do
    test "writes a pruned spec to priv/hearth/<name>.yaml" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, "priv/hearth/petstore.yaml")
      yaml = created_file(igniter, "priv/hearth/petstore.yaml")

      assert {:ok, parsed} = YamlElixir.read_from_string(yaml)
      assert parsed["openapi"]
      assert Map.has_key?(parsed["paths"], "/pets")
    end

    test "--tag prunes the spec's paths to the selected operations" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--tag",
          "pets:list_pets"
        ])

      parsed =
        igniter
        |> created_file("priv/hearth/petstore.yaml")
        |> YamlElixir.read_from_string!()

      # only list_pets survives — its sibling create_pets (POST /pets)
      # and show_pet_by_id (/pets/{petId}) are pruned out
      assert Map.keys(parsed["paths"]) == ["/pets"]
      refute Map.has_key?(parsed["paths"]["/pets"], "post")
    end

    test "the notice lists the pruned spec" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert notice_text(igniter) =~ "priv/hearth/petstore.yaml"
    end
  end

  describe "create-only — gen never overwrites" do
    test "halts when the integration's Layer 1 module already exists" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "lib/test/integrations/petstore.ex" =>
              "defmodule Test.Integrations.Petstore do\nend\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "Test.Integrations.Petstore already exists") and
                 String.contains?(issue, "only creates") and
                 String.contains?(issue, "mix hearth.regen petstore")
             end)

      refute notice_text(igniter) =~ "Spec loaded"
    end

    test "halts on a partial deletion — only Layer 2 left, Layer 1 gone" do
      igniter =
        test_project(
          files: %{
            "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
            "lib/test/integrations/petstore/petstore_api.ex" =>
              "defmodule Test.Integrations.Petstore.PetstoreApi do\nend\n"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "Test.Integrations.Petstore already exists") and
                 String.contains?(issue, "petstore/petstore_api.ex")
             end)

      refute notice_text(igniter) =~ "Spec loaded"
    end

    test "a fresh project still generates" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert igniter.issues == []
      assert_creates(igniter, "lib/test/integrations/petstore.ex")
    end

    test "re-running the same gen halts on the second run" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "already exists"))
    end
  end
end
