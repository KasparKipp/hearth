defmodule Mix.Tasks.Hearth.Gen.SelectionTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: operation selection and argument validation.

  import ExUnit.CaptureIO

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  # A JSON spec with `count` GET operations, all under one "Things" tag,
  # for exercising the operation-count gate.
  defp big_spec_json(count) do
    paths =
      Map.new(1..count, fn i ->
        {"/thing#{i}", %{"get" => %{"operationId" => "getThing#{i}", "tags" => ["Things"]}}}
      end)

    JSON.encode!(%{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Big API", "version" => "1.0.0"},
      "paths" => paths
    })
  end

  describe "operation selection and the --n-operations gate" do
    test "a spec under the gate proceeds and reports the selection" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert notice_text(igniter) =~ "Selected 3 of 3 operations across 1 tag."
    end

    test "a spec over the gate with no --tag halts with the tag-discovery listing" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "30 operations") and
                 String.contains?(issue, "limit (25)") and
                 String.contains?(issue, ~s("Things":)) and
                 String.contains?(issue, ":get_thing1") and
                 String.contains?(issue, "--n-operations 30")
             end)

      refute notice_text(igniter) =~ "Selected"
    end

    test "--tag skips the gate even when the spec is over the limit" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--tag",
          "Things"
        ])

      assert notice_text(igniter) =~ "Selected 30 of 30 operations across 1 tag."
    end

    test "--tag narrows the selection to specific operationIds" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--tag",
          "Things:get_thing1,get_thing2"
        ])

      assert notice_text(igniter) =~ "Selected 2 of 30 operations"
    end

    test "--n-operations raises the gate so a big spec proceeds" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/big.json",
          "--integration",
          "Big",
          "--n-operations",
          "30"
        ])

      assert notice_text(igniter) =~ "Selected 30 of 30 operations"
    end

    test "a malformed --tag value halts with the parse error" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json", "--tag", "Things:a:b"])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "comma-separated"))
      refute notice_text(igniter) =~ "Selected"
    end

    test "the gate discovery echoes the real source and integration in the subset command" do
      igniter =
        test_project(files: %{"priv/specs/big.json" => big_spec_json(30)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/big.json", "--integration", "Big"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(
                 issue,
                 "mix hearth.gen priv/specs/big.json --integration Big"
               ) and String.contains?(issue, ~s(--tag "Things:get_thing1,))
             end)
    end

    test "the subset command spells out every tag with its operationIds, one --tag per line" do
      spec =
        JSON.encode!(%{
          "openapi" => "3.0.0",
          "info" => %{"title" => "Multi", "version" => "1.0"},
          "paths" => %{
            "/a" => %{"get" => %{"operationId" => "getA", "tags" => ["Search"]}},
            "/b" => %{"get" => %{"operationId" => "getB", "tags" => ["Validation"]}}
          }
        })

      output =
        capture_io(fn ->
          test_project(files: %{"priv/specs/multi.json" => spec})
          |> Igniter.compose_task("hearth.gen", [
            "priv/specs/multi.json",
            "--integration",
            "Multi",
            "--list"
          ])
        end)

      assert output =~
               ~s(mix hearth.gen priv/specs/multi.json --integration Multi \\\n) <>
                 ~s(    --tag "Search:get_a" \\\n    --tag "Validation:get_b")
    end
  end

  describe "--integration / --domain validation" do
    defp gen_with(args) do
      test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
      |> Igniter.compose_task("hearth.gen", ["priv/specs/petstore.yaml" | args])
    end

    for bad <- ["Foo Bar", "123", "", "Foo.Bar"] do
      test "rejects --integration #{inspect(bad)} with a clear issue, no crash" do
        igniter = gen_with(["--integration", unquote(bad)])

        assert Enum.any?(igniter.issues, fn issue ->
                 String.contains?(issue, "--integration") and
                   String.contains?(issue, "not a valid module name")
               end)

        refute notice_text(igniter) =~ "Spec loaded"
      end
    end

    test "rejects a malformed --domain" do
      igniter = gen_with(["--integration", "Petstore", "--domain", "bad value"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "--domain") and
                 String.contains?(issue, "not a valid module name")
             end)
    end

    test "accepts a snake_case --integration, camelizing it" do
      igniter = gen_with(["--integration", "send_grid"])

      assert igniter.issues == []
      assert_creates(igniter, "lib/test/integrations/send_grid.ex")

      assert created_file(igniter, "lib/test/integrations/send_grid.ex") =~
               "defmodule Test.Integrations.SendGrid do"
    end
  end

  describe "--n-operations validation" do
    for bad <- ["-5", "0"] do
      test "rejects --n-operations #{bad}" do
        igniter =
          test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
          |> Igniter.compose_task("hearth.gen", [
            "priv/specs/petstore.yaml",
            "--integration",
            "Petstore",
            "--n-operations",
            unquote(bad)
          ])

        assert Enum.any?(
                 igniter.issues,
                 &String.contains?(&1, "--n-operations must be a positive integer")
               )

        refute notice_text(igniter) =~ "Spec loaded"
      end
    end

    test "accepts a positive --n-operations" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore",
          "--n-operations",
          "3"
        ])

      assert igniter.issues == []
      assert notice_text(igniter) =~ "Selected 3 of 3 operations"
    end
  end
end
