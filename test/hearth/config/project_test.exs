defmodule Hearth.Config.ProjectTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Hearth.Config
  alias Hearth.Config.Project

  @stripe [
    module: MyApp.Integrations.Stripe,
    source: "priv/specs/stripe.yaml",
    base_path: "/v1"
  ]

  defp content(igniter) do
    {:ok, source} = Rewrite.source(igniter.rewrite, ".hearth.exs")
    Rewrite.Source.get(source, :content)
  end

  defp integrations(igniter) do
    {:ok, integrations} = igniter |> content() |> Config.parse()
    integrations
  end

  describe "read/1" do
    test "a project without .hearth.exs has no integrations" do
      assert {:ok, %Igniter{}, []} = Project.read(test_project())
    end

    test "returns the file's integrations" do
      igniter =
        test_project(files: %{".hearth.exs" => "[integrations: [stripe: #{inspect(@stripe)}]]"})

      assert {:ok, _igniter, [stripe: @stripe]} = Project.read(igniter)
    end

    test "a malformed file is an error" do
      igniter = test_project(files: %{".hearth.exs" => "[integrations: :oops]"})

      assert {:error, message} = Project.read(igniter)
      assert message =~ ".hearth.exs"
    end
  end

  describe "put_integration/3" do
    test "creates .hearth.exs from the template when it's missing" do
      igniter = Project.put_integration(test_project(), :stripe, @stripe)

      assert_creates(igniter, ".hearth.exs")
      assert integrations(igniter) == [stripe: @stripe]
      assert content(igniter) =~ "# Hearth integrations"
      assert content(igniter) =~ "module: MyApp.Integrations.Stripe"
    end

    test "adds an entry, keeping the others and the user's comments" do
      existing = """
      # my notes
      [
        integrations: [
          # billing
          paddle: [module: MyApp.Integrations.Paddle]
        ]
      ]
      """

      igniter =
        test_project(files: %{".hearth.exs" => existing})
        |> Project.put_integration(:stripe, @stripe)

      assert integrations(igniter) == [
               paddle: [module: MyApp.Integrations.Paddle],
               stripe: @stripe
             ]

      assert content(igniter) =~ "# my notes"
      assert content(igniter) =~ "# billing"
    end

    test "replaces an existing entry with the same key" do
      igniter =
        test_project(files: %{".hearth.exs" => "[integrations: [stripe: [module: Old.Stripe]]]"})
        |> Project.put_integration(:stripe, @stripe)

      assert integrations(igniter) == [stripe: @stripe]
    end
  end

  describe "put_integration/3 with a selection" do
    test "writes tag names that aren't plain atoms as quoted keys" do
      tags = [
        "Customer Accounts": [include: ["listAccounts"], exclude: ["deleteAccount"]],
        pets: :all
      ]

      igniter = Project.put_integration(test_project(), :stripe, @stripe ++ [tags: tags])

      assert content(igniter) =~ ~s|"Customer Accounts": [|
      assert integrations(igniter) == [stripe: @stripe ++ [tags: tags]]
    end
  end

  describe "put_module/3" do
    test "changes only the entry's module" do
      igniter =
        test_project(files: %{".hearth.exs" => "[integrations: [stripe: #{inspect(@stripe)}]]"})
        |> Project.put_module(:stripe, MyApp.Payments.Stripe)

      assert integrations(igniter) == [
               stripe: Keyword.put(@stripe, :module, MyApp.Payments.Stripe)
             ]
    end
  end
end
