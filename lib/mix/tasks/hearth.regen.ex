defmodule Mix.Tasks.Hearth.Regen.Docs do
  @moduledoc false

  def short_doc do
    "Regenerates Hearth integrations from their pruned specs. Requires igniter to run."
  end

  def example do
    "mix hearth.regen stripe"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Usage

        mix hearth.regen <integration>[,<integration>...] [--yes]
        mix hearth.regen --all [--yes]
        mix hearth.regen <integration>[,<integration>...] --sync [--yes]
        mix hearth.regen <integration> --module <Layer1Module> [--remove-old] [--yes]

    `<integration>` is the name the integration was generated with
    (`mix hearth.gen … --integration Stripe`). `stripe` and `Stripe`
    both name the `stripe:` entry in `.hearth.exs` and read
    `priv/hearth/stripe.yaml`. Separate several names with commas.
    `--all` regenerates every integration in `.hearth.exs`. With
    neither, the task halts.

    Regeneration reads the integration's pruned spec (written by
    `mix hearth.gen`) and re-renders the three layers and the auth
    test. The `.hearth.exs` entry's `module:` names the Layer 1
    module; every other layer is derived from it. Its `base_path:`
    and `source:` reproduce what `gen` chose. The external test is a user-owned
    scaffold — it is never overwritten.

    The entry's `tags:` decides which operations the pruned spec holds.
    If they no longer match — you moved an operation between
    `include:` and `exclude:`, or switched a tag to `:all` / `:none` —
    regen halts and asks for `--sync`.

    If any named integration can't be regenerated, nothing is written.

    ## Re-pruning from the source

    `--sync` re-prunes the pruned spec from the entry's `source:` with
    its `tags:`, re-records `tags:`, lists the operations added and
    removed, and regenerates. Use it after editing `tags:`, or after
    pointing `source:` at a newer version of the spec. `source:` must
    be a local spec file. `--sync --all` asks for confirmation first
    (`--yes` skips it) — run `mix hearth.diff --all` to see the drift.

    When a function goes away — renamed, or now covered by a
    `prefixed_ids` function — `--sync` asks to rename its calls across
    lib and test, Mox expectations included. It asks before appending
    external tests for new functions, and lists tests that still call an
    operation it removed. `--yes` accepts both.

    ## Moving an integration

    `--module` regenerates exactly one integration into a new
    namespace — `mix hearth.regen stripe --module MyApp.Payments.Stripe`.
    The module must end in the integration name. It creates the new
    modules (halting if any exist), points the `.hearth.exs` entry at
    them, and wires the new mock and config like `mix hearth.gen`. The old
    modules and their config are left untouched: delete them once
    callers have switched.

    Add `--remove-old` to remove the old module in the same run: its
    files, every config entry keyed by its modules, its commented
    alternate base URLs and its `defmock`. Files you have claimed are
    kept and listed — a `hearth:owned` / `hearth:collaborating` token,
    or the external test scaffold.

    ## Ownership tokens

    `mix hearth.gen` only creates; `mix hearth.regen` updates. Each
    generated file may opt out of regeneration with a moduledoc token:

      * `hearth:owned` — the file is skipped entirely. Put this on a
        file you have hand-edited and want to keep.
      * `hearth:collaborating` — `regen` prompts before overwriting it.
      * _(no token)_ — the file is overwritten silently. The default.

    To change which operations are generated, edit the entry's `tags:`
    in `.hearth.exs` and run `mix hearth.regen <integration> --sync`.

    ## Options

      * `--all` — regenerate every integration in `.hearth.exs`.
      * `--module <Layer1Module>` — move one integration into a new
        namespace (see above).
      * `--remove-old` — with `--module`, remove the old module too.
      * `--sync` — re-prune the pruned spec from `source:` with `tags:`
        first (see above).
      * `--yes` — non-interactive: accept every `hearth:collaborating`
        prompt.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Hearth.Regen do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Hearth.Config
    alias Hearth.Config.Project
    alias Hearth.Fs.Content
    alias Hearth.Fs.Ownership
    alias Hearth.Gen.Patches
    alias Hearth.Integration.Manifest
    alias Hearth.Integration.Messages, as: IntegrationMessages
    alias Hearth.Integration.Names
    alias Hearth.Regen.CallSites
    alias Hearth.Regen.Messages
    alias Hearth.Regen.Move
    alias Hearth.Regen.Sync
    alias Hearth.Render.ModuleNames
    alias Hearth.Spec.Auth
    alias Hearth.Spec.BasePath
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.PrefixedIds
    alias Hearth.Spec.Selection
    alias Hearth.Spec.Servers

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [
          all: :boolean,
          module: :string,
          remove_old: :boolean,
          sync: :boolean,
          yes: :boolean
        ],
        # Optional so a bare `mix hearth.regen` halts with a
        # task-specific message rather than Igniter's generic error.
        positional: [{:integrations, optional: true}],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      with {:ok, igniter, %{integrations: integrations, registry: registry}} <-
             Project.load(igniter),
           igniter = Igniter.assign(igniter, :hearth_registry, registry),
           {:ok, selected} <- select(igniter, integrations),
           {:ok, target} <- target_module(igniter, selected),
           :ok <- confirm_sync_all(igniter, selected) do
        Enum.reduce(selected, igniter, &regen(&2, &1, target))
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp select(igniter, integrations) do
      Names.select(
        integrations,
        igniter.args.positional[:integrations],
        igniter.args.options[:all],
        :regen
      )
    end

    # `--module` moves exactly one integration into a new namespace. The
    # last segment must stay the integration name, so the pruned spec
    # path and every derived module name stay consistent.
    defp target_module(igniter, selected) do
      module = igniter.args.options[:module]

      cond do
        is_nil(module) and igniter.args.options[:remove_old] ->
          {:error, Messages.remove_old_needs_module_message()}

        is_nil(module) ->
          {:ok, nil}

        igniter.args.options[:all] || length(selected) != 1 ->
          {:error, Messages.module_needs_one_message()}

        true ->
          [{key, _entry}] = selected
          parse_target(module, key)
      end
    end

    defp parse_target(value, key) do
      integration = key |> Atom.to_string() |> Macro.camelize()

      with {:ok, module} <- ModuleNames.parse(value),
           true <- List.last(Module.split(module)) == integration do
        {:ok, module}
      else
        :error -> {:error, Messages.bad_target_message(value)}
        false -> {:error, Messages.target_rename_message(value, integration)}
      end
    end

    defp regen(igniter, {key, entry}, target) do
      spec_path = Names.spec_path(key)

      with {:ok, layer1} <- layer1(key, entry),
           {:ok, igniter, spec, changes} <- pruned_spec(igniter, key, entry, spec_path) do
        names = ModuleNames.from_layer1(layer1)

        cond do
          target == layer1 and igniter.args.options[:remove_old] ->
            Igniter.add_issue(igniter, Messages.remove_old_needs_module_message())

          target in [nil, layer1] ->
            {igniter, old_functions} = CallSites.functions(igniter, names)

            {replacements, rewrite?, changes} =
              plan_sync(igniter, old_functions, spec, entry, changes)

            igniter
            |> Sync.extend_external_test(names, spec, changes)
            |> render(names, spec_path, spec, entry)
            |> wire_new_auth(names, changes)
            |> CallSites.rewrite(names, replacements, rewrite?)

          true ->
            new = ModuleNames.from_layer1(target)

            Move.run(igniter, names, new, %{
              key: key,
              render: &render(&1, new, spec_path, spec, entry),
              wiring: wiring(igniter, new, spec, entry)
            })
        end
      else
        {:halt, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # `--sync` changed the auth scheme: wire its credential config the
    # way `gen` would (existing values are kept).
    defp wire_new_auth(igniter, names, %{auth: auth}) when not is_nil(auth) do
      otp_app = Igniter.Project.Application.app_name(igniter)
      Patches.wire_credential(igniter, otp_app, names, auth)
    end

    defp wire_new_auth(igniter, _names, _changes), do: igniter

    # `--sync` only: which removed functions to replace at their call
    # sites (`Hearth.Regen.CallSites`), whether the user agreed, and the
    # changes for the external test — "added" means a function the old
    # Layer 2 didn't have, and renames the call-site rewrite handles are
    # left out of its notices.
    defp plan_sync(_igniter, _old, _spec, _entry, nil), do: {[], false, nil}

    defp plan_sync(igniter, old, spec, entry, changes) do
      prefixed =
        case PrefixedIds.prepare(spec, entry) do
          {:ok, prefixed} -> prefixed
          {:error, _detail} -> nil
        end

      replacements = CallSites.replacements(old, spec, prefixed, changes.renamed)
      rewrite? = CallSites.accept?(igniter, replacements)

      # A rename's new name isn't new: its calls are the old ones.
      renamed_to = MapSet.new(changes.renamed, &elem(&1, 1))

      added =
        for op <- functions(Operation.extract(spec), prefixed),
            not MapSet.member?(old, op.id),
            not MapSet.member?(renamed_to, op.id),
            do: {op.method, op.path}

      renamed = if rewrite?, do: [], else: changes.renamed
      {replacements, rewrite?, %{changes | added: added, renamed: renamed}}
    end

    defp layer1(key, entry) do
      case Config.module(entry) do
        {:ok, layer1} -> {:ok, layer1}
        {:error, value} -> {:halt, Messages.bad_module_message(key, value)}
      end
    end

    # `--sync` re-prunes the spec from its source (`Hearth.Regen.Sync`).
    # Otherwise the pruned spec is read as is, and must still hold
    # exactly what the entry's `tags:` select.
    defp pruned_spec(igniter, key, entry, spec_path) do
      if igniter.args.options[:sync] do
        Sync.run(igniter, key, entry, spec_path)
      else
        with true <- Igniter.exists?(igniter, spec_path) or :missing,
             igniter = Igniter.include_existing_file(igniter, spec_path),
             {:ok, bytes} <- Content.read(igniter, spec_path),
             {:ok, spec} <- Loader.decode(bytes, :yaml),
             :ok <- check_selection(key, entry, spec_path, spec),
             :ok <- check_auth(key, entry, spec_path, spec) do
          {:ok, igniter, spec, nil}
        else
          :missing ->
            {:halt, Messages.missing_spec_message(spec_path)}

          {:halt, message} ->
            {:halt, message}

          {:error, reason} ->
            {:halt, "hearth.regen: failed to parse #{spec_path}: #{format_reason(reason)}"}
        end
      end
    end

    defp check_selection(key, entry, spec_path, spec) do
      operations = Operation.extract(spec)

      exempt =
        case PrefixedIds.prepare(spec, entry) do
          {:ok, prefixed} -> unselected_targets(operations, entry, prefixed)
          {:error, _detail} -> []
        end

      with {:ok, rule} <- Selection.rule(entry),
           [_ | _] = problems <- Selection.check(rule, operations -- exempt) do
        {:halt, Messages.selection_mismatch_message(key, spec_path, problems)}
      else
        :none -> :ok
        [] -> :ok
        {:error, detail} -> {:halt, IntegrationMessages.bad_tags_message(:regen, key, detail)}
      end
    end

    # The entry's `auth: [scheme: …]` must be the scheme the pruned spec
    # wires; a changed choice is applied with `--sync`.
    defp check_auth(key, entry, spec_path, spec) do
      case Auth.auth_scheme(entry) do
        {:ok, nil} ->
          :ok

        {:ok, scheme} ->
          if Auth.primary(spec) == scheme,
            do: :ok,
            else:
              {:halt, Messages.auth_mismatch_message(key, spec_path, scheme, Auth.primary(spec))}

        {:error, value} ->
          {:halt, IntegrationMessages.bad_auth_message(:regen, key, value, [])}
      end
    end

    defp wiring(igniter, names, spec, entry) do
      %{
        otp_app: Igniter.Project.Application.app_name(igniter),
        names: names,
        auth: Auth.strategy(spec),
        servers: Servers.resolve(spec),
        prefix: prefix(entry, Operation.extract(spec))
      }
    end

    # The base path comes from the `.hearth.exs` entry — the prefix
    # `gen` folded into Layer 1 and `config/test.exs`. Recomputing it
    # from the pruned subset can yield a longer prefix and desync from
    # that config; it is only the fallback for an entry without one. A
    # hand-edit can add a path outside the recorded prefix — halt then,
    # rather than strip the wrong segments.
    defp render(igniter, names, spec_path, spec, entry) do
      operations = Operation.extract(spec)
      prefix = prefix(entry, operations)

      if BasePath.prefix_of_all?(operations, prefix) do
        render_prefixed(igniter, names, {spec_path, spec, entry}, operations, prefix)
      else
        Igniter.add_issue(
          igniter,
          Messages.base_path_mismatch_message(spec_path, prefix, operations)
        )
      end
    end

    defp render_prefixed(igniter, names, {spec_path, spec, entry}, operations, prefix) do
      case PrefixedIds.prepare(spec, entry) do
        {:ok, prefixed} ->
          functions = functions(operations, prefixed)
          render_layers(igniter, names, {spec_path, spec, entry, prefixed}, functions, prefix)

        {:error, detail} ->
          key = Config.key(names.integration)
          message = IntegrationMessages.bad_prefixed_ids_message(:regen, key, detail)
          Igniter.add_issue(igniter, message)
      end
    end

    # The operations that become functions: all of the pruned spec's,
    # minus the ones a `prefixed_ids:` function reaches, selected or not.
    defp functions(operations, prefixed) do
      operations -- Enum.map(PrefixedIds.covered(operations, prefixed), &elem(&1, 0))
    end

    defp unselected_targets(_operations, _entry, nil), do: []

    defp unselected_targets(operations, entry, prefixed) do
      targets = PrefixedIds.targets(operations, prefixed.resources, prefixed.functions)

      case Selection.rule(entry) do
        {:ok, rule} -> targets -- Selection.select(targets, rule)
        _none -> targets
      end
    end

    defp prefix(entry, operations),
      do: Config.base_path(entry) || BasePath.common_prefix(operations)

    defp render_layers(igniter, names, {spec_path, spec, entry, prefixed}, operations, prefix) do
      otp_app = Igniter.Project.Application.app_name(igniter)
      auth = Auth.strategy(spec)
      servers = Servers.resolve(spec)
      selected = BasePath.strip(operations, prefix)

      # The three layers and the auth test are `:tracked` —
      # ownership-token-aware. The external test is a `:scaffold` —
      # a user-owned file `regen` creates once and never overwrites.
      # `source` is the spec `gen` ran on, so Layer 2's moduledoc
      # matches what gen wrote; the pruned spec path is the fallback.
      files =
        Manifest.files(names,
          otp_app: otp_app,
          auth: auth,
          servers: servers,
          prefix: prefix,
          operations: selected,
          metadata: Manifest.metadata(Config.source(entry) || spec_path, spec),
          prefixed: prefixed
        )

      {igniter, results} =
        Enum.reduce(files, {igniter, []}, fn entry, {acc, results} ->
          {acc, result} = regen_file(acc, entry)
          {acc, [result | results]}
        end)

      Igniter.add_notice(igniter, Messages.regen_notice(names, spec_path, Enum.reverse(results)))
    end

    defp regen_file(igniter, %{module: module, content: content, kind: kind, policy: :scaffold}) do
      location = Igniter.Project.Module.proper_location(igniter, module, kind)

      if Igniter.exists?(igniter, location) do
        {igniter, {location, :kept}}
      else
        {Igniter.create_new_file(igniter, location, content), {location, :created}}
      end
    end

    defp regen_file(igniter, %{module: module, content: content, kind: kind, policy: :tracked}) do
      location = Igniter.Project.Module.proper_location(igniter, module, kind)

      if Igniter.exists?(igniter, location) do
        igniter = Igniter.include_existing_file(igniter, location)

        # Fail closed: a file whose ownership token can't be read is
        # skipped, never overwritten — it may be `hearth:owned`.
        case Content.read(igniter, location) do
          {:ok, existing} ->
            apply_token(igniter, location, content, Ownership.classify(existing))

          {:error, _reason} ->
            {igniter, {location, :unreadable}}
        end
      else
        {Igniter.create_new_file(igniter, location, content), {location, :created}}
      end
    end

    defp apply_token(igniter, location, _content, :owned) do
      {igniter, {location, :owned}}
    end

    defp apply_token(igniter, location, content, :none) do
      {overwrite(igniter, location, content), {location, :regenerated}}
    end

    defp apply_token(igniter, location, content, :collaborating) do
      if accept?(igniter, location) do
        {overwrite(igniter, location, content), {location, :regenerated}}
      else
        {igniter, {location, :declined}}
      end
    end

    defp overwrite(igniter, location, content) do
      Igniter.create_new_file(igniter, location, content, on_exists: :overwrite)
    end

    # `hearth:collaborating` files prompt per file. `--yes` and test
    # mode accept without asking.
    # `--sync --all` re-prunes every integration from its source — a
    # potentially huge change. Ask first; `--yes` and test mode accept.
    defp confirm_sync_all(igniter, selected) do
      cond do
        !(igniter.args.options[:sync] && igniter.args.options[:all]) -> :ok
        igniter.args.options[:yes] || igniter.assigns[:test_mode?] -> :ok
        Mix.shell().yes?(Messages.sync_all_prompt(Keyword.keys(selected)), default: :no) -> :ok
        true -> {:error, Messages.sync_all_declined_message()}
      end
    end

    defp accept?(igniter, location) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?("hearth.regen: #{location} is hearth:collaborating — regenerate it?",
          default: :no
        )
    end

    defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
    defp format_reason(reason), do: inspect(reason)
  end
else
  defmodule Mix.Tasks.Hearth.Regen do
    @shortdoc "#{Mix.Tasks.Hearth.Regen.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc Mix.Tasks.Hearth.Regen.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'hearth.regen' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
