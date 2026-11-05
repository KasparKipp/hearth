if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Gen.TestConfig do
    @moduledoc false

    # Sets a value in `config/test.exs`, keeping one already set.
    #
    # Not `Igniter.Project.Config.configure/6`: for "test.exs" it also
    # creates `config/dev.exs` and `config/prod.exs` (bare
    # `import Config`) when missing, and appends
    # `import_config "#{config_env()}.exs"` to `config/config.exs`
    # unless an `import_config` sits at its top level — so a project
    # without a prod.exs got an empty one, and a config.exs that imports
    # test.exs inside an `if` got a second import. Hearth needs neither
    # file: prod values live in `config/runtime.exs`. Instead,
    # `config/test.exs` is created when missing and `config/config.exs`
    # made to load it (`ensure_loaded/1`), leaving every other file alone.
    # Both follow mix.exs `config_path`, like `configure/6` does: an
    # umbrella child's (`"../../config/config.exs"`) are the umbrella's.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    @import_test """
    if config_env() == :test do
      import_config "test.exs"
    end
    """

    @spec configure(Igniter.t(), atom(), [atom()], Macro.t()) :: Igniter.t()
    def configure(igniter, otp_app, config_path, value) do
      {config_exs, test_exs} = paths(igniter)

      igniter
      |> ensure_loaded(config_exs, test_exs)
      |> Igniter.update_elixir_file(test_exs, fn zipper ->
        zipper
        |> Igniter.Project.Config.modify_config_code(config_path, otp_app, value,
          updater: &{:ok, &1}
        )
        |> case do
          :error -> {:warning, failed(test_exs, otp_app, config_path, value)}
          other -> other
        end
      end)
    end

    # The project's config file and the test.exs beside it.
    defp paths(igniter) do
      config_exs = Igniter.Project.Application.config_path(igniter)
      {config_exs, config_exs |> Path.dirname() |> Path.join("test.exs")}
    end

    # Callers set a module's key (`[Layer1, :base_url]`); a deeper path
    # would need a nested example, so it doesn't match.
    defp failed(test_exs, otp_app, [module, key], value) do
      """
      Could not set #{inspect([otp_app, module, key])} in #{test_exs}. Add:

          config #{inspect(otp_app)}, #{inspect(module)}, #{key}: #{Sourceror.to_string(value)}
      """
    end

    # test.exs exists, and the config file imports it.
    defp ensure_loaded(igniter, config_exs, test_exs) do
      igniter
      |> Igniter.create_or_update_elixir_file(test_exs, "import Config\n", &{:ok, &1})
      |> Igniter.create_or_update_elixir_file(
        config_exs,
        "import Config\n\n" <> @import_test,
        &import_test/1
      )
    end

    defp import_test(zipper) do
      if imports_test?(Sourceror.Zipper.node(zipper)),
        do: {:ok, zipper},
        else: {:ok, Igniter.Code.Common.add_code(zipper, @import_test)}
    end

    # Any `import_config` that could load test.exs — "test.exs" itself,
    # an interpolated `"#{config_env()}.exs"`, or anything computed —
    # counts; only an import of some other literal file doesn't.
    defp imports_test?(ast) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:import_config, _meta, [arg]} = node, found? -> {node, found? or loads_test?(arg)}
          node, found? -> {node, found?}
        end)

      found?
    end

    defp loads_test?({:__block__, _meta, [path]}) when is_binary(path),
      do: Path.basename(path) == "test.exs"

    defp loads_test?(_arg), do: true
  end
end
