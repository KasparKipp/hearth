if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Regen.ExternalSetup do
    @moduledoc false

    # Every regen: the external test is a user-owned scaffold that gen
    # writes once, so values the entry gained since — a credential after
    # an auth switch, a `headers:` key added later — aren't set up there.
    # Read from the file's text: a config value whose `<INT>_<KEY>` it
    # never mentions gets a seeding `setup` block, y/N; an option value it
    # never passes gets a notice, since passing it means editing every
    # call.

    alias Hearth.Fs.Content
    alias Hearth.Gen.Patches
    alias Hearth.Regen.Messages
    alias Hearth.Spec.Auth
    alias Hearth.Spec.Values

    @spec run(Igniter.t(), map(), Values.values(), Auth.strategy()) :: Igniter.t()
    def run(igniter, names, values, auth) do
      location = Igniter.Project.Module.proper_location(igniter, names.external_test, :test)
      igniter = Igniter.include_existing_file(igniter, location)

      # A missing scaffold is created whole, already set up.
      with true <- Igniter.exists?(igniter, location),
           {:ok, content} <- Content.read(igniter, location) do
        keyed? = Auth.keyed?(auth)

        # `config/test.exs` sets the base URL; the scaffold never seeds it.
        unseeded = missing(content, names, Values.config_keys(values, keyed?) -- [:base_url])
        unpassed = missing(content, names, option_keys(values, keyed?), &"#{&1}:")

        igniter
        |> seed(names, location, unseeded)
        |> note_unpassed(location, unpassed)
      else
        _ -> igniter
      end
    end

    # `{key, env_var}` for each key the file doesn't mention — by its env
    # var, or by `mention`.
    defp missing(content, names, keys, mention \\ nil) do
      for key <- keys,
          env_var = Patches.env_var(names.integration, key),
          not String.contains?(content, if(mention, do: mention.(key), else: env_var)),
          do: {key, env_var}
    end

    defp option_keys(values, keyed?) do
      credential = if keyed?, do: [values.credential], else: []

      for {:option, key} <-
            credential ++ Enum.map(values.headers, &elem(&1, 1)) ++ [values.base_url],
          do: key
    end

    defp seed(igniter, _names, _location, []), do: igniter

    defp seed(igniter, names, location, unseeded) do
      env_vars = Enum.map(unseeded, &elem(&1, 1))

      if accept?(igniter, location, env_vars) do
        otp_app = Igniter.Project.Application.app_name(igniter)
        keys = Enum.map(unseeded, &elem(&1, 0))
        code = Hearth.Render.Tests.external_seed_setup(names.layer1, otp_app, keys)

        igniter
        |> Igniter.update_elixir_file(location, &not_async(&1, names.external_test))
        |> Igniter.update_elixir_file(location, &append(&1, names.external_test, code))
        |> Igniter.add_notice(Messages.external_seeded_notice(location, env_vars))
      else
        Igniter.add_notice(igniter, Messages.external_unseeded_notice(location, env_vars))
      end
    end

    # Seeding app config is process-global: `async: true` becomes false.
    defp not_async(zipper, module) do
      with {:ok, zipper} <- Igniter.Code.Module.move_to_defmodule(zipper, module),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
           {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :use,
               2,
               &Igniter.Code.Function.argument_equals?(&1, 0, ExUnit.Case)
             ) do
        Igniter.Code.Function.update_nth_argument(zipper, 1, &set_async_false/1)
      else
        :error -> {:ok, zipper}
      end
    end

    defp set_async_false(options) do
      Igniter.Code.Keyword.set_keyword_key(options, :async, false, fn value ->
        {:ok, Igniter.Code.Common.replace_code(value, false)}
      end)
    end

    defp append(zipper, module, code) do
      with {:ok, zipper} <- Igniter.Code.Module.move_to_defmodule(zipper, module),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
        {:ok, Igniter.Code.Common.add_code(zipper, code)}
      else
        :error -> {:warning, "Could not find #{inspect(module)} to add a setup block to."}
      end
    end

    defp note_unpassed(igniter, _location, []), do: igniter

    defp note_unpassed(igniter, location, unpassed),
      do: Igniter.add_notice(igniter, Messages.external_unpassed_notice(location, unpassed))

    defp accept?(igniter, location, env_vars) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?(Messages.external_seed_prompt(location, env_vars), default: :no)
    end
  end
end
