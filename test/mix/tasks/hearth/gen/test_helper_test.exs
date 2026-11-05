defmodule Mix.Tasks.Hearth.Gen.TestHelperTest do
  use Hearth.TaskCase, async: true

  # `mix hearth.gen`: excluding `:external` in `test/test_helper.exs`.
  # `ExUnit.configure/1` replaces the `:exclude` option, so a project's
  # own excludes must be added to, never shadowed by a second call.

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")
  @helper "test/test_helper.exs"

  defp gen(helper) do
    files = %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml}
    files = if helper, do: Map.put(files, @helper, helper), else: files

    test_project(files: files)
    |> Igniter.compose_task("hearth.gen", [
      "priv/specs/petstore.yaml",
      "--integration",
      "Petstore"
    ])
  end

  defp gen_helper(helper), do: helper |> gen() |> created_file(@helper)

  defp count(text, fragment), do: length(String.split(text, fragment)) - 1

  # The tags a helper leaves excluded: the `exclude:` of its last
  # `ExUnit.start/1` / `ExUnit.configure/1` call, evaluated with the
  # file's top-level assignments (`rest = [...]`) bound. Raises unless
  # the helper is valid Elixir.
  defp effective_exclude(helper) do
    exprs =
      case Code.string_to_quoted!(helper) do
        {:__block__, _, exprs} -> exprs
        expr -> [expr]
      end

    {_ast, excludes} =
      Macro.prewalk(exprs, [], fn
        {{:., _, [{:__aliases__, _, [:ExUnit]}, fun]}, _, [opts]} = call, acc
        when fun in [:start, :configure] and is_list(opts) ->
          if Keyword.has_key?(opts, :exclude),
            do: {call, [opts[:exclude] | acc]},
            else: {call, acc}

        node, acc ->
          {node, acc}
      end)

    assignments = Enum.filter(exprs, &match?({:=, _, _}, &1))
    {value, _binding} = Code.eval_quoted({:__block__, [], assignments ++ [hd(excludes)]})
    value
  end

  describe "a helper with no exclude" do
    test "gets one" do
      helper = gen_helper("ExUnit.start()\n")

      assert helper =~ "ExUnit.start()"
      assert helper =~ "ExUnit.configure(exclude: [:external])"
    end

    test "a missing helper is created with one" do
      igniter =
        test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
        |> Igniter.rm(@helper)
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/petstore.yaml",
          "--integration",
          "Petstore"
        ])

      assert_creates(igniter, @helper)
      assert created_file(igniter, @helper) =~ "ExUnit.configure(exclude: [:external])"
    end

    test "options other than exclude are kept" do
      helper = gen_helper("ExUnit.start(capture_log: true)\n")

      assert helper =~ "ExUnit.start(capture_log: true)"
      assert helper =~ "ExUnit.configure(exclude: [:external])"
    end
  end

  describe "a helper that already excludes tags" do
    test "ExUnit.start/1 opts: :external joins the project's excludes" do
      helper = gen_helper("ExUnit.start(exclude: [:foo, :smart_id])\n")

      assert helper =~ "ExUnit.start(exclude: [:foo, :smart_id, :external])"
      refute helper =~ "ExUnit.configure("
    end

    test "ExUnit.start/1 opts beside other options" do
      helper = gen_helper("ExUnit.start(capture_log: true, exclude: [:slow])\n")

      assert helper =~ "ExUnit.start(capture_log: true, exclude: [:slow, :external])"
      refute helper =~ "ExUnit.configure("
    end

    test "ExUnit.configure/1: :external joins the project's excludes" do
      helper = gen_helper("ExUnit.start()\nExUnit.configure(exclude: [:foo, :smart_id])\n")

      assert helper =~ "ExUnit.configure(exclude: [:foo, :smart_id, :external])"
      assert count(helper, "ExUnit.configure(") == 1
    end

    test "tag filters with values are kept, :external goes before them" do
      helper = gen_helper("ExUnit.start(exclude: [:slow, integration: true])\n")

      assert helper =~ "ExUnit.start(exclude: [:slow, :external, integration: true])"
      refute helper =~ "ExUnit.configure("
    end

    test "every call that sets exclude gets :external, whichever runs last" do
      helper =
        gen_helper("""
        ExUnit.start(exclude: [:slow])

        if System.get_env("CI") do
          ExUnit.configure(exclude: [:flaky])
        end
        """)

      assert helper =~ "ExUnit.start(exclude: [:slow, :external])"
      assert helper =~ "ExUnit.configure(exclude: [:flaky, :external])"
      assert count(helper, "ExUnit.configure(") == 1
    end

    test "comments and other code are kept" do
      helper =
        gen_helper("""
        # Network suites are opt-in: mix test --include smart_id
        ExUnit.start(
          # slow ones too
          exclude: [:foo, :smart_id]
        )

        Mox.defmock(MyApp.ClockMock, for: MyApp.Clock)
        Application.put_env(:my_app, :clock, MyApp.ClockMock)
        """)

      assert helper =~ "# Network suites are opt-in: mix test --include smart_id"
      assert helper =~ "# slow ones too"
      assert helper =~ ~r/exclude: \[:foo, :smart_id, :external\]/
      assert helper =~ "Mox.defmock(MyApp.ClockMock, for: MyApp.Clock)"
      assert helper =~ "Application.put_env(:my_app, :clock, MyApp.ClockMock)"
      refute helper =~ "ExUnit.configure("
    end

    test "a cons tail: :external joins the head, or the file is left alone with a warning" do
      original = "rest = [:flaky]\nExUnit.start(exclude: [:slow | rest])\n"
      igniter = gen(original)
      helper = created_file(igniter, @helper)

      if helper == original do
        assert Enum.any?(igniter.warnings, &(&1 =~ "test/test_helper.exs" and &1 =~ ":external"))
      else
        assert Enum.sort(effective_exclude(helper)) == [:external, :flaky, :slow]
      end
    end

    test "a helper the old gen clobbered gets the project's excludes back" do
      # What gen used to write: a trailing configure that replaces
      # `:foo`. `:external` joins `start/1`'s list and the line goes.
      helper =
        gen_helper("ExUnit.start(exclude: [:foo])\n\nExUnit.configure(exclude: [:external])\n")

      assert Enum.sort(effective_exclude(helper)) == [:external, :foo]
      assert helper =~ "ExUnit.start(exclude: [:foo, :external])"
      refute helper =~ "ExUnit.configure("
    end

    test "an exclude that isn't a literal list is left alone, with a warning" do
      original = "excludes = [:foo]\nExUnit.start(exclude: excludes)\n"
      igniter = gen(original)

      assert_unchanged(igniter, @helper)
      assert Enum.any?(igniter.warnings, &(&1 =~ "test/test_helper.exs" and &1 =~ ":external"))
    end

    test "the notice doesn't list the helper when it was left alone" do
      igniter = gen("excludes = [:foo]\nExUnit.start(exclude: excludes)\n")
      refute notice_text(igniter) =~ "test/test_helper.exs (:external exclude)"

      igniter = gen("ExUnit.start(exclude: [:foo])\n")
      assert notice_text(igniter) =~ "test/test_helper.exs (:external exclude)"
    end

    test "a clobbered helper with a non-literal exclude: the warning names the old line" do
      original =
        "excludes = [:foo]\nExUnit.start(exclude: excludes)\n\nExUnit.configure(exclude: [:external])\n"

      igniter = gen(original)

      assert_unchanged(igniter, @helper)

      assert Enum.any?(
               igniter.warnings,
               &(&1 =~ "test/test_helper.exs" and &1 =~ "ExUnit.configure(exclude: [:external])" and
                   &1 =~ "remove")
             )
    end

    test "Hearth's old configure line alone is kept: it's the only exclude" do
      "ExUnit.start()\n\nExUnit.configure(exclude: [:external])\n"
      |> gen()
      |> assert_unchanged(@helper)
    end
  end

  describe "re-running is a no-op when :external is already excluded" do
    for {form, helper} <- [
          {"ExUnit.configure/1, alone",
           "ExUnit.start()\nExUnit.configure(exclude: [:external])\n"},
          {"ExUnit.configure/1, among others",
           "ExUnit.start()\nExUnit.configure(exclude: [:foo, :external])\n"},
          {"ExUnit.start/1 opts", "ExUnit.start(exclude: [:foo, :external])\n"},
          {"a tag filter", "ExUnit.start(exclude: [external: true])\n"},
          {"a cons list with :external in its head",
           "excludes = [:slow]\nExUnit.start(exclude: [:external | excludes])\n"}
        ] do
      test "#{form}" do
        unquote(helper) |> gen() |> assert_unchanged(@helper)
      end
    end

    test "a second gen leaves the first one's exclude alone" do
      tictactoe = File.read!("test/fixtures/specs/tictactoe-3.1.yaml")

      test_project(
        files: %{
          "priv/specs/petstore.yaml" => @petstore_3_0_yaml,
          "priv/specs/tictactoe.yaml" => tictactoe,
          @helper => "ExUnit.start(exclude: [:foo])\n"
        }
      )
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/petstore.yaml",
        "--integration",
        "Petstore"
      ])
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/tictactoe.yaml",
        "--integration",
        "Tictactoe"
      ])
      |> assert_unchanged(@helper)
    end
  end
end
