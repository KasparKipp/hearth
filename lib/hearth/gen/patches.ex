if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Gen.Patches do
    @moduledoc false

    # The host-project wiring `mix hearth.gen` applies around the
    # generated files: consumer deps, the Mox mock, `test_helper.exs`,
    # and the config patches (credential, impl, base URL, alternates).
    # Every patch is idempotent.
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
      |> Igniter.Project.Deps.add_dep({:req, "~> 0.7"}, on_exists: :skip)
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
      |> compile_test_support()
      |> patch_test_helper()
      |> patch_credential_config(otp_app, names.layer1, names.integration, auth)
      |> wire_headers(otp_app, names, ctx[:headers] || [])
      |> patch_impl_config(otp_app, names.layer2, names.mock)
      |> patch_base_url_config(otp_app, names.layer1, servers, prefix)
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
      marker = alternates_marker(layer1)

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
    # Call it right after `add_deps/1`, before `wire/2` — `wire/2` can
    # touch `mix.exs` too (`elixirc_paths`), which needs no fetch.
    def fetch_deps_if_changed(igniter) do
      if Igniter.has_changes?(igniter, ["mix.exs"]) do
        Igniter.add_task(igniter, "deps.get")
      else
        igniter
      end
    end

    # The mock lives in `test/support`, which a `mix new` project doesn't
    # compile — add it to `elixirc_paths(:test)`. Igniter leaves a project
    # that already sets `elixirc_paths` (e.g. Phoenix) untouched.
    defp compile_test_support(igniter), do: Igniter.Project.Test.ensure_test_support(igniter)

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

    # Wires the credential alone — for `regen --sync` when the source's
    # auth scheme changed. Keeps any value already configured.
    @spec wire_credential(Igniter.t(), atom(), map(), term()) :: Igniter.t()
    def wire_credential(igniter, otp_app, names, auth),
      do: patch_credential_config(igniter, otp_app, names.layer1, names.integration, auth)

    # The credential lives in `config/runtime.exs`, keyed by the Layer 1
    # module (where `credential/1` reads it): prod raises if the env var
    # is unset, dev falls back to a placeholder. Skipped when the spec
    # declares no usable auth scheme.
    defp patch_credential_config(igniter, _otp_app, _layer1, _integration, :none), do: igniter

    defp patch_credential_config(igniter, _otp_app, _layer1, _integration, {:unsupported, _}),
      do: igniter

    defp patch_credential_config(igniter, otp_app, layer1, integration, _auth),
      do: configure_from_env(igniter, otp_app, layer1, integration, :api_key)

    # Each `headers:` config key, wired like the credential from its own
    # `<INT>_<KEY>` env var. Keeps any value already configured — also
    # what `regen --sync` uses when headers join an entry.
    @spec wire_headers(Igniter.t(), atom(), map(), [{String.t(), atom()}]) :: Igniter.t()
    def wire_headers(igniter, otp_app, names, headers) do
      Enum.reduce(headers, igniter, fn {_name, key}, igniter ->
        configure_from_env(igniter, otp_app, names.layer1, names.integration, key)
      end)
    end

    defp configure_from_env(igniter, otp_app, layer1, integration, key) do
      env_var = String.upcase(Macro.underscore(integration) <> "_" <> Atom.to_string(key))

      prod =
        Sourceror.parse_string!(
          ~s/System.get_env("#{env_var}") || raise("missing #{env_var} environment variable")/
        )

      dev = Sourceror.parse_string!(~s/System.get_env("#{env_var}") || "DEV_NO_#{env_var}"/)

      igniter
      |> Igniter.Project.Config.configure_runtime_env(
        :prod,
        otp_app,
        [layer1, key],
        {:code, prod},
        updater: &{:ok, &1}
      )
      |> Igniter.Project.Config.configure_runtime_env(
        :dev,
        otp_app,
        [layer1, key],
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

    defp alternates_marker(layer1), do: "# Hearth: alternate base URLs for #{inspect(layer1)}"

    # Undoes `wire/2` for an integration `regen --module --remove-old`
    # moved away: every `config` entry keyed by its Layer 1 or Layer 2
    # module, the commented alternates, and its `defmock`. A
    # `config_env()` block left empty goes too.
    @spec unwire(Igniter.t(), atom(), map()) :: Igniter.t()
    def unwire(igniter, otp_app, names) do
      modules = [names.layer1, names.layer2]
      alternates = ~r/\n?#{Regex.escape(alternates_marker(names.layer1))}.*\n(# config .*\n)*/

      ~w(config/config.exs config/test.exs config/runtime.exs)
      |> Enum.reduce(igniter, fn path, acc ->
        update_text(acc, path, fn content ->
          content
          |> String.replace(alternates, "")
          |> cut(&config_for?(&1, otp_app, modules))
          |> cut(&empty_env_block?/1)
        end)
      end)
      |> update_text("test/support/mocks.ex", &cut(&1, fn z -> defmock_for?(z, names.mock) end))
    end

    defp update_text(igniter, path, fun) do
      if Igniter.exists?(igniter, path) do
        Igniter.update_file(igniter, path, fn source ->
          Rewrite.Source.update(source, :content, fun.(Rewrite.Source.get(source, :content)))
        end)
      else
        igniter
      end
    end

    defp config_for?(zipper, otp_app, modules) do
      Igniter.Code.Function.function_call?(zipper, :config, 3) and
        Igniter.Code.Function.argument_equals?(zipper, 0, otp_app) and
        Enum.any?(modules, &Igniter.Code.Function.argument_equals?(zipper, 1, &1))
    end

    defp empty_env_block?(zipper) do
      match?(
        {:if, _, [{:==, _, [{:config_env, _, _}, _]}, [{_do, {:__block__, _, []}}]]},
        Sourceror.Zipper.node(zipper)
      )
    end

    defp defmock_for?(zipper, mock) do
      Igniter.Code.Function.function_call?(zipper, {Mox, :defmock}, 2) and
        Igniter.Code.Function.argument_equals?(zipper, 0, mock)
    end

    # Cuts every node matching `pred` out of the source text, located by
    # its Sourceror range. Editing the text rather than removing AST
    # nodes keeps every comment and the surrounding formatting, and
    # sidesteps Sourceror's trailing-comment blocks, which crash once
    # their only expression is removed. Blank lines left behind are
    # collapsed.
    defp cut(content, pred) do
      {_zipper, ranges} =
        content
        |> Sourceror.parse_string!()
        |> Sourceror.Zipper.zip()
        |> Sourceror.Zipper.traverse([], fn zipper, acc ->
          if pred.(zipper),
            do: {zipper, [Sourceror.get_range(Sourceror.Zipper.node(zipper)) | acc]},
            else: {zipper, acc}
        end)

      ranges
      |> Enum.sort_by(&{&1.start[:line], &1.start[:column]}, :desc)
      |> Enum.reduce(String.split(content, "\n"), &cut_range/2)
      |> Enum.join("\n")
      |> tidy()
    end

    # Ranges are 1-based; the end column is exclusive.
    defp cut_range(%{start: [line: sl, column: sc], end: [line: el, column: ec]}, lines) do
      prefix = lines |> Enum.at(sl - 1) |> String.slice(0, sc - 1)
      suffix = lines |> Enum.at(el - 1) |> String.slice((ec - 1)..-1//1)

      Enum.take(lines, sl - 1) ++ [prefix <> suffix] ++ Enum.drop(lines, el)
    end

    defp tidy(content) do
      content
      |> String.replace(~r/[ \t]+$/m, "")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.replace(~r/(\bdo)\n\n+/, "\\1\n")
      |> String.replace(~r/\n\n+(\s*end\b)/, "\n\\1")
      |> String.trim()
      |> Kernel.<>("\n")
    end

    def wired_files(auth, headers \\ []) do
      base = [
        "test/support/mocks.ex",
        "mix.exs (test/support in elixirc_paths)",
        "test/test_helper.exs (:external exclude)",
        "config/test.exs (impl, base_url)"
      ]

      runtime =
        case auth do
          :none -> []
          {:unsupported, _} -> []
          _ -> ["credential"]
        end ++ if(headers == [], do: [], else: ["headers"])

      if runtime == [],
        do: base,
        else: base ++ ["config/runtime.exs (#{Enum.join(runtime, ", ")})"]
    end
  end
end
