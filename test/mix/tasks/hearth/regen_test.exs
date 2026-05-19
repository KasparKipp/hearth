defmodule Mix.Tasks.Hearth.RegenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  @layer1 "lib/test/integrations/petstore.ex"
  @layer2 "lib/test/integrations/petstore/petstore_api.ex"
  @layer3 "lib/test/integrations/petstore/petstore_api/req.ex"
  @external "test/test/integrations/petstore_external_test.exs"

  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  defp created_file(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  defp owned_layer1 do
    """
    defmodule Test.Integrations.Petstore do
      @moduledoc \"\"\"
      Raw client.

      hearth:owned
      \"\"\"
      def hand_written, do: :mine
    end
    """
  end

  defp regen(igniter),
    do: Igniter.compose_task(igniter, "hearth.regen", ["Test.Integrations.Petstore"])

  describe "the pruned spec" do
    test "regenerates the layers from priv/hearth/<name>.yaml" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @layer2)
      assert_creates(igniter, @layer3)

      assert created_file(igniter, @layer1) =~ "defmodule Test.Integrations.Petstore do"
      assert created_file(igniter, @layer2) =~ "@callback list_pets("
    end

    test "halts when the pruned spec is missing" do
      igniter =
        test_project()
        |> regen()

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "no pruned spec for Petstore") and
                 String.contains?(issue, "priv/hearth/petstore.yaml")
             end)
    end

    test "halts with a helpful message when no integration is named" do
      igniter =
        test_project()
        |> Igniter.compose_task("hearth.regen", [])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "name the integration's Layer 1 module") and
                 String.contains?(issue, "MyApp.Integrations.Stripe")
             end)
    end
  end

  describe "ownership tokens" do
    test "a hearth:owned file is skipped, keeping its hand-edits" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => owned_layer1()
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      refute created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "skipping #{@layer1} (hearth:owned)"
    end

    test "a file with no token is overwritten" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => "defmodule Test.Integrations.Petstore do\nend\n"
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end

    test "a hearth:collaborating file is regenerated when the prompt is accepted" do
      collaborating =
        "defmodule Test.Integrations.Petstore do\n  @moduledoc \"hearth:collaborating\"\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @layer1 => collaborating
          }
        )
        |> regen()

      # test mode auto-accepts the per-file prompt
      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end
  end

  describe "the external test scaffold" do
    test "is created when absent" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert_creates(igniter, @external)
    end

    test "is never overwritten — even without an ownership token" do
      edited = "defmodule Test.Integrations.PetstoreExternalTest do\n  # user edited\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
            @external => edited
          }
        )
        |> regen()

      assert created_file(igniter, @external) =~ "# user edited"
      assert notice_text(igniter) =~ "keeping #{@external}"
    end
  end
end
