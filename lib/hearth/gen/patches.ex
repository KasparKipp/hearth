if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Gen.Patches do
    @moduledoc false

    # The host-project wiring `mix hearth.gen` applies around the
    # generated files: consumer deps, the Mox mock, `test_helper.exs`,
    # and the config patches (credential, impl, base URL, alternates,
    # `:hearth_domains`). Every patch is idempotent.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    # The generated code needs `req` at runtime and `mox` (test only)
    # for the generated mock. Both ride into Hearth only transitively
    # via the optional, dev-time `igniter` dep, so the consuming app
    # needs them as direct deps of its own. Added by `hearth.gen` rather
    # than `hearth.install` because it is the *generated code* that
    # needs them. `on_exists: :skip` leaves a consumer's existing dep
    # untouched — no prompt, no overwrite.
    #
    # `plug` (for the generated Layer 1 test) is deliberately NOT
    # added: `req` already declares it as an optional all-environment
    # dependency, so a consumer dep scoped `only: :test` would diverge
    # and break the build. The test self-guards on
    # `Code.ensure_loaded?(Plug.Conn)` instead. `mox` has no such
    # parent declaration, so `only: :test` is safe for it.
    @spec add_deps(Igniter.t()) :: Igniter.t()
    def add_deps(igniter) do
      igniter
      |> Igniter.Project.Deps.add_dep({:req, "~> 0.5"}, on_exists: :skip)
      |> Igniter.Project.Deps.add_dep({:mox, "~> 1.0", only: [:test]}, on_exists: :skip)
    end

    # Applies every host-project patch, in a fixed order (the order
    # determines the layout of the patched config files). `ctx` carries
    # `:otp_app`, `:names` (a `ModuleNames.from_layer1/1` map), `:auth`,
    # `:servers`, and `:prefix`.
    @spec wire(Igniter.t(), map()) :: Igniter.t()
    def wire(igniter, ctx) do
      %{otp_app: otp_app, names: names, auth: auth, servers: servers, prefix: prefix} = ctx

      igniter
      |> wire_mock(names.mock, names.layer2)
      |> patch_test_helper()
      |> patch_credential_config(otp_app, names.layer1, names.integration, auth)
      |> patch_impl_config(otp_app, names.layer2, names.mock)
      |> patch_base_url_config(otp_app, names.layer1, servers, prefix)
      |> patch_hearth_domains(otp_app, names.layer2)
      |> patch_base_url_alternates(otp_app, names.layer1, servers, prefix)
      |> warn_servers(otp_app, names.layer1, servers)
    end

    # `config/test.exs` overrides Layer 1's base URL with a non-prod
    # server, so the external test points there (not at production).
    # The shared path prefix is folded in, matching Layer 1's @base_url.
    # 0 servers → a placeholder; `warn_servers/3` flags it.
    defp patch_base_url_config(igniter, otp_app, layer1, servers, prefix) do
      url = with_prefix(servers.test || "https://api.example.com", prefix)

      Igniter.Project.Config.configure(
        igniter,
        "test.exs",
        otp_app,
        [layer1, :base_url],
        {:code, Sourceror.parse_string!(inspect(url))},
        updater: &{:ok, &1}
      )
    end

    # Extra server URLs the spec offered are surfaced as commented-out
    # config overrides: prod-candidates in `config/config.exs`, non-prod
    # in `config/test.exs`. Appended idempotently (per-integration marker).
    defp patch_base_url_alternates(igniter, otp_app, layer1, servers, prefix) do
      igniter
      |> append_alternates("config.exs", otp_app, layer1, servers.default_alternates, prefix)
      |> append_alternates("test.exs", otp_app, layer1, servers.test_alternates, prefix)
    end

    defp append_alternates(igniter, _file, _otp_app, _layer1, [], _prefix), do: igniter

    defp append_alternates(igniter, file, otp_app, layer1, urls, prefix) do
      marker = "# Hearth: alternate base URLs for #{inspect(layer1)}"

      lines =
        Enum.map_join(urls, "\n", fn url ->
          "# config #{inspect(otp_app)}, #{inspect(layer1)}, " <>
            "base_url: #{inspect(with_prefix(url, prefix))}"
        end)

      block = marker <> " — uncomment one to switch.\n" <> lines <> "\n"

      Igniter.create_or_update_file(igniter, "config/#{file}", block, fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, marker) do
          source
        else
          Rewrite.Source.update(source, :content, content <> "\n" <> block)
        end
      end)
    end

    # When the spec declared no `servers`, the base URL is a placeholder
    # — warn the user where to set the real one.
    defp warn_servers(igniter, otp_app, layer1, %{warn?: true}) do
      Igniter.add_warning(igniter, """
      The spec declared no `servers` — Layer 1's base URL is a placeholder.
      Set the real one:

          config #{inspect(otp_app)}, #{inspect(layer1)}, base_url: "https://api.example.com"
      """)
    end

    defp warn_servers(igniter, _otp_app, _layer1, %{fallback_default?: true}) do
      Igniter.add_notice(
        igniter,
        "Every spec server looked non-production; used the first as the default base URL."
      )
    end

    defp warn_servers(igniter, _otp_app, _layer1, _servers), do: igniter

    defp with_prefix(url, ""), do: url
    defp with_prefix(url, prefix), do: String.trim_trailing(url, "/") <> prefix

    # When `mix hearth.gen` added `req`/`mox` to the consumer's
    # `mix.exs`, queue `mix deps.get` so its `mix.lock` is set up — the
    # generated code is otherwise uncompilable until the user fetches.
    # Skipped when `mix.exs` was untouched (the deps already present).
    def fetch_deps_if_changed(igniter) do
      if Igniter.has_changes?(igniter, ["mix.exs"]) do
        Igniter.add_task(igniter, "deps.get")
      else
        igniter
      end
    end

    # `:external`-tagged tests hit the real network — make them opt-in
    # by excluding the `:external` tag in `test/test_helper.exs`. The
    # `exclude: [:external]` substring is its own idempotency marker.
    defp patch_test_helper(igniter) do
      Igniter.create_or_update_file(
        igniter,
        "test/test_helper.exs",
        "ExUnit.start()\nExUnit.configure(exclude: [:external])\n",
        fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, "exclude: [:external]") do
            source
          else
            Rewrite.Source.update(
              source,
              :content,
              content <> "\nExUnit.configure(exclude: [:external])\n"
            )
          end
        end
      )
    end

    # Creates `test/support/mocks.ex` if absent, else appends one more
    # guarded `Mox.defmock` line — idempotent: the mock module name is a
    # unique marker, so a re-run for the same integration is a no-op.
    defp wire_mock(igniter, mock, layer2) do
      Igniter.create_or_update_file(
        igniter,
        "test/support/mocks.ex",
        Hearth.Render.Mocks.render(mock, layer2),
        fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, inspect(mock)) do
            source
          else
            appended =
              (content <> "\n" <> Hearth.Render.Mocks.defmock_line(mock, layer2) <> "\n")
              |> Code.format_string!()
              |> IO.iodata_to_binary()
              |> Kernel.<>("\n")

            Rewrite.Source.update(source, :content, appended)
          end
        end
      )
    end

    # The credential lives in `config/runtime.exs`, keyed by the Layer 1
    # module (where `credential/1` reads it): prod raises if the env var
    # is unset, dev falls back to a placeholder. Skipped when the spec
    # declares no usable auth scheme.
    defp patch_credential_config(igniter, _otp_app, _layer1, _integration, :none), do: igniter

    defp patch_credential_config(igniter, _otp_app, _layer1, _integration, {:unsupported, _}),
      do: igniter

    defp patch_credential_config(igniter, otp_app, layer1, integration, _auth) do
      env_var = String.upcase(Macro.underscore(integration)) <> "_API_KEY"

      prod =
        Sourceror.parse_string!(
          ~s/System.get_env("#{env_var}") || raise("missing #{env_var} environment variable")/
        )

      dev = Sourceror.parse_string!(~s/System.get_env("#{env_var}") || "DEV_NO_#{env_var}"/)

      igniter
      |> Igniter.Project.Config.configure_runtime_env(
        :prod,
        otp_app,
        [layer1, :api_key],
        {:code, prod},
        updater: &{:ok, &1}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :dev,
        otp_app,
        [layer1, :api_key],
        {:code, dev},
        updater: &{:ok, &1}
      )
    end

    # `config/test.exs` points the Layer 2 dispatcher at the Mox mock;
    # prod/dev fall back to Layer 3 with no config. `updater` keeps an
    # existing value on re-run.
    defp patch_impl_config(igniter, otp_app, layer2, mock) do
      Igniter.Project.Config.configure(
        igniter,
        "test.exs",
        otp_app,
        [layer2, :impl],
        {:code, Sourceror.parse_string!(inspect(mock))},
        updater: &{:ok, &1}
      )
    end

    # Appends the Layer 2 module to `:hearth_domains`. `append_new_to_list`
    # is idempotent, and returns `:error` (→ no-op) when the value is not
    # a list — so an explicit `false` opt-out is left untouched.
    defp patch_hearth_domains(igniter, otp_app, layer2) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        otp_app,
        [:hearth_domains],
        {:code, Sourceror.parse_string!("[#{inspect(layer2)}]")},
        updater: fn zipper ->
          Igniter.Code.List.append_new_to_list(zipper, Sourceror.parse_string!(inspect(layer2)))
        end
      )
    end

    def wired_files(auth) do
      base = [
        "test/support/mocks.ex",
        "test/test_helper.exs (:external exclude)",
        "config/config.exs (:hearth_domains)",
        "config/test.exs (impl, base_url)"
      ]

      case auth do
        :none -> base
        {:unsupported, _} -> base
        _ -> base ++ ["config/runtime.exs (credential)"]
      end
    end
  end
end
