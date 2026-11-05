defmodule Mix.Tasks.Hearth.Regen.NoTerminalTest do
  # Swaps the global Mix shell to answer prompts.
  use Hearth.TaskCase, async: false

  # regen's y/N questions when nobody can answer them. Igniter 0.8, outside
  # its own test env, adds `yes: true` to a task's options whenever stdin
  # isn't a terminal (`Igniter.Mix.Task.set_yes/2`), so piped or CI runs
  # look like `--yes`. Only a `--yes` on the command line accepts; with no
  # terminal, every question is declined.
  #
  # The `:hearth_tty?` assign stands in for the terminal check, and wins
  # over test mode, which accepts every question when it's absent (the
  # rest of the suite relies on that). `Mix.Shell.Process.yes?/2` raises
  # when no answer is queued, so a question asked without a terminal fails
  # the test rather than hanging it.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @layer1 "lib/test/integrations/petstore.ex"
  @external "test/test/integrations/petstore_external_test.exs"

  @collaborating """
  defmodule Test.Integrations.Petstore do
    @moduledoc "hearth:collaborating"
    def hand_written, do: :mine
  end
  """

  @collaborating_project %{
    "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
    ".hearth.exs" => "[integrations: [petstore: [module: Test.Integrations.Petstore]]]",
    @layer1 => @collaborating
  }

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  # What Igniter does before running a task from a pipe: parse argv, then
  # imply `--yes`. Igniter's test env skips that step, so this repeats it.
  defp piped(igniter, argv) do
    task = Mix.Tasks.Hearth.Regen
    args = task.parse_argv(argv)
    args = %{args | options: Keyword.put(args.options, :yes, true)}

    %{igniter | args: args}
    |> Igniter.assign(:hearth_tty?, false)
    |> task.igniter()
  end

  defp in_terminal(igniter, argv) do
    igniter
    |> Igniter.assign(:hearth_tty?, true)
    |> Igniter.compose_task("hearth.regen", argv)
  end

  defp shell_info do
    receive do
      {:mix_shell, :info, [line]} -> [line | shell_info()]
    after
      0 -> []
    end
  end

  describe "a hearth:collaborating file, run without a terminal" do
    test "Igniter's implied --yes doesn't count: the file is kept" do
      igniter = test_project(files: @collaborating_project) |> piped(["petstore"])

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      refute created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "skipping #{@layer1} (hearth:collaborating, declined)"
    end

    test "the declined question says --yes accepts it" do
      igniter = test_project(files: @collaborating_project) |> piped(["petstore"])

      # Printed as it's declined, or in the notice at the end.
      assert Enum.any?(
               [notice_text(igniter) | shell_info()],
               &(&1 =~ @layer1 and &1 =~ "--yes")
             )
    end

    test "--no-yes keeps it too: a pipe turns it into yes: true as well" do
      igniter = test_project(files: @collaborating_project) |> piped(["petstore", "--no-yes"])

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
    end

    test "--yes on the command line regenerates it" do
      igniter = test_project(files: @collaborating_project) |> piped(["petstore", "--yes"])

      assert created_file(igniter, @layer1) =~ "def new("
      refute created_file(igniter, @layer1) =~ "hand_written"
    end
  end

  describe "a hearth:collaborating file, in a terminal" do
    test "answering n keeps it" do
      send(self(), {:mix_shell_input, :yes?, false})
      igniter = test_project(files: @collaborating_project) |> in_terminal(["petstore"])

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      assert_received {:mix_shell, :yes?, [question]}
      assert question =~ @layer1
    end

    test "answering y regenerates it" do
      send(self(), {:mix_shell_input, :yes?, true})
      igniter = test_project(files: @collaborating_project) |> in_terminal(["petstore"])

      assert created_file(igniter, @layer1) =~ "def new("
    end
  end

  describe "--sync's questions, run without a terminal" do
    # gen with `--tag pets:listPets`, applied: the pruned spec holds only
    # GET /pets.
    defp gen_list_pets do
      test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/petstore.yaml",
        "--integration",
        "Petstore",
        "--tag",
        "pets:listPets"
      ])
      |> apply_igniter!()
    end

    defp select_create_too(igniter) do
      igniter
      |> Hearth.Config.Project.put_fields(:petstore,
        tags: [pets: [include: ["listPets", "createPets"], exclude: ["showPetById"]]]
      )
      |> apply_igniter!()
    end

    test "--sync --all is cancelled" do
      igniter = gen_list_pets() |> select_create_too() |> piped(["--all", "--sync"])

      assert issue_text(igniter) =~ "--sync --all cancelled"
    end

    test "--sync doesn't append external tests for added operations" do
      igniter = gen_list_pets() |> select_create_too() |> piped(["petstore", "--sync"])

      refute created_file(igniter, @external) =~ "create_pets"
      assert notice_text(igniter) =~ "Left #{@external} alone"
    end

    test "--sync doesn't seed a new credential into the external test" do
      unsecured = %{
        "openapi" => "3.0.0",
        "info" => %{"title" => "Pay", "version" => "1"},
        "servers" => [%{"url" => "https://api.pay.test"}],
        "paths" => %{"/v1/charges" => %{"get" => %{"operationId" => "GetCharges"}}}
      }

      bearer =
        Map.merge(unsecured, %{
          "security" => [%{"bearerAuth" => []}],
          "components" => %{
            "securitySchemes" => %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}}
          }
        })

      external = "test/test/integrations/pay_external_test.exs"

      igniter =
        test_project(files: %{"priv/specs/pay.json" => JSON.encode!(unsecured)})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/pay.json", "--integration", "Pay"])
        |> apply_igniter!()
        |> Igniter.create_new_file("priv/specs/pay.json", JSON.encode!(bearer),
          on_exists: :overwrite
        )
        |> Hearth.Config.Project.put_fields(:pay, auth: [scheme: "bearerAuth"])
        |> apply_igniter!()
        |> piped(["pay", "--sync"])

      refute created_file(igniter, external) =~ "PAY_API_KEY"
      assert notice_text(igniter) =~ "Left #{external} alone"
    end

    test "--sync doesn't rename the calls to a renamed operation" do
      app = "lib/test/pets.ex"

      igniter =
        gen_list_pets()
        |> Igniter.create_new_file(app, """
        defmodule Test.Pets do
          alias Test.Integrations.Petstore.PetstoreApi

          def all, do: PetstoreApi.list_pets()
        end
        """)
        |> Hearth.Config.Project.put_fields(:petstore,
          overrides: [operation_ids: %{"listPets" => "listAllPets"}]
        )
        |> apply_igniter!()
        |> piped(["petstore", "--sync"])

      assert created_file(igniter, app) =~ "PetstoreApi.list_pets()"
      assert notice_text(igniter) =~ "rename their calls by hand"
    end
  end

  # A cheap guard on top of the tests above: regen's code never reads the
  # `:yes` option. gen's install prompt (`hearth.gen.ex`) still does, on
  # purpose: it only adds `:hearth` to `.formatter.exs`, and accepting
  # from a pipe is what Igniter's own installers do.
  test "no regen question reads the :yes option, which Igniter sets for a pipe" do
    readers =
      ["lib/mix/tasks/hearth.regen.ex" | Path.wildcard("lib/hearth/regen/**/*.ex")]
      |> Enum.filter(
        &(File.read!(&1) =~ ~r/options\[:yes\]|options\.yes|get\([^)]*options, :yes/)
      )

    assert readers == []
  end
end
