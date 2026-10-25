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
        mix hearth.regen <integration> --module <Layer1Module> [--remove-old] [--yes]

    `<integration>` is the name the integration was generated with
    (`mix hearth.gen … --integration Stripe`). `stripe` and `Stripe`
    both read `priv/hearth/stripe.yaml`. Separate several names with
    commas. `--all` regenerates every pruned spec under
    `priv/hearth/`. With neither, the task halts.

    Regeneration reads the integration's pruned spec (written by
    `mix hearth.gen`) and re-renders the three layers and the auth
    test. The spec's `x-hearth.module` names the Layer 1 module; every
    other layer is derived from it. The external test is a user-owned
    scaffold — it is never overwritten.

    If any named integration can't be regenerated, nothing is written.

    ## Moving an integration

    `--module` regenerates exactly one integration into a new
    namespace — `mix hearth.regen stripe --module MyApp.Payments.Stripe`.
    The module must end in the integration name. It creates the new
    modules (halting if any exist), points `x-hearth.module` at them,
    and wires the new mock and config like `mix hearth.gen`. The old
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

    To pull in upstream spec changes, edit
    `priv/hearth/<integration>.yaml` and re-run `mix hearth.regen`.

    ## Options

      * `--all` — regenerate every integration under `priv/hearth/`.
      * `--module <Layer1Module>` — move one integration into a new
        namespace (see above).
      * `--remove-old` — with `--module`, remove the old module too.
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

    alias Hearth.Fs.Content
    alias Hearth.Fs.Ownership
    alias Hearth.Integration.Manifest
    alias Hearth.Regen.Messages
    alias Hearth.Regen.Move
    alias Hearth.Render.ModuleNames
    alias Hearth.Spec.Auth
    alias Hearth.Spec.BasePath
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Meta
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Servers

    @spec_dir "priv/hearth"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [all: :boolean, module: :string, remove_old: :boolean, yes: :boolean],
        # Optional so a bare `mix hearth.regen` halts with a
        # task-specific message rather than Igniter's generic error.
        positional: [{:integrations, optional: true}],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      with {:ok, igniter, paths} <- spec_paths(igniter),
           {:ok, target} <- target_module(igniter, paths) do
        Enum.reduce(paths, igniter, &regen(&2, &1, target))
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # `--all` → every pruned spec under `priv/hearth/`; otherwise the
    # comma-separated integration names, each mapped to its pruned spec.
    defp spec_paths(igniter) do
      case {igniter.args.positional[:integrations], igniter.args.options[:all]} do
        {nil, true} -> all_spec_paths(igniter)
        {nil, _} -> {:error, Messages.missing_integration_message()}
        {_names, true} -> {:error, Messages.names_and_all_message()}
        {names, _} -> named_spec_paths(igniter, names)
      end
    end

    defp all_spec_paths(igniter) do
      igniter = Igniter.include_glob(igniter, Path.join(@spec_dir, "*.yaml"))

      paths =
        igniter.rewrite
        |> Rewrite.paths()
        |> Enum.filter(&(Path.dirname(&1) == @spec_dir and Path.extname(&1) == ".yaml"))
        |> Enum.sort()

      case paths do
        [] -> {:error, Messages.no_specs_message()}
        paths -> {:ok, igniter, paths}
      end
    end

    defp named_spec_paths(igniter, arg) do
      names =
        arg
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      case {names, Enum.reject(names, &ModuleNames.valid_segment?/1)} do
        {[], _} ->
          {:error, Messages.missing_integration_message()}

        {names, []} ->
          paths = Enum.map(names, &Manifest.pruned_spec_path(Macro.camelize(&1)))
          {:ok, igniter, Enum.uniq(paths)}

        {_names, bad} ->
          {:error, Messages.bad_names_message(bad)}
      end
    end

    # `--module` moves exactly one integration into a new namespace. The
    # last segment must stay the integration name, so the pruned spec
    # path and every derived module name stay consistent.
    defp target_module(igniter, paths) do
      module = igniter.args.options[:module]

      cond do
        is_nil(module) and igniter.args.options[:remove_old] ->
          {:error, Messages.remove_old_needs_module_message()}

        is_nil(module) ->
          {:ok, nil}

        igniter.args.options[:all] || length(paths) != 1 ->
          {:error, Messages.module_needs_one_message()}

        true ->
          parse_target(module, hd(paths))
      end
    end

    defp parse_target(value, spec_path) do
      integration = spec_path |> Path.basename(".yaml") |> Macro.camelize()

      with {:ok, module} <- ModuleNames.parse(value),
           true <- List.last(Module.split(module)) == integration do
        {:ok, module}
      else
        :error -> {:error, Messages.bad_target_message(value)}
        false -> {:error, Messages.target_rename_message(value, integration)}
      end
    end

    defp regen(igniter, spec_path, target) do
      with true <- Igniter.exists?(igniter, spec_path) or :missing,
           igniter = Igniter.include_existing_file(igniter, spec_path),
           {:ok, bytes} <- Content.read(igniter, spec_path),
           {:ok, spec} <- Loader.decode(bytes, :yaml),
           {:ok, layer1} <- layer1(spec) do
        names = ModuleNames.from_layer1(layer1)

        cond do
          target == layer1 and igniter.args.options[:remove_old] ->
            Igniter.add_issue(igniter, Messages.remove_old_needs_module_message())

          target in [nil, layer1] ->
            render(igniter, names, spec_path, spec)

          true ->
            new = ModuleNames.from_layer1(target)

            Move.run(igniter, names, new, %{
              spec_path: spec_path,
              bytes: bytes,
              spec: spec,
              render: &render(&1, new, spec_path, spec),
              wiring: wiring(igniter, new, spec)
            })
        end
      else
        :missing ->
          Igniter.add_issue(igniter, Messages.missing_spec_message(spec_path))

        {:bad_module, value} ->
          Igniter.add_issue(igniter, Messages.bad_module_message(spec_path, value))

        {:error, reason} ->
          Igniter.add_issue(
            igniter,
            "hearth.regen: failed to parse #{spec_path}: #{format_reason(reason)}"
          )
      end
    end

    defp layer1(spec) do
      value = Meta.module(spec)

      case ModuleNames.parse(value) do
        {:ok, layer1} -> {:ok, layer1}
        :error -> {:bad_module, value}
      end
    end

    defp wiring(igniter, names, spec) do
      %{
        otp_app: Igniter.Project.Application.app_name(igniter),
        names: names,
        auth: Auth.strategy(spec),
        servers: Servers.resolve(spec),
        prefix: prefix(spec, Operation.extract(spec))
      }
    end

    # The base path comes from the pruned spec's `x-hearth` block — the
    # prefix `gen` folded into Layer 1 and `config/test.exs`. Recomputing
    # it from the pruned subset can yield a longer prefix and desync
    # from that config; it is only the fallback for a spec without the
    # block. A hand-edit can add a path outside the recorded prefix —
    # halt then, rather than strip the wrong segments.
    defp render(igniter, names, spec_path, spec) do
      operations = Operation.extract(spec)
      prefix = prefix(spec, operations)

      if BasePath.prefix_of_all?(operations, prefix) do
        render_layers(igniter, names, spec_path, spec, operations, prefix)
      else
        Igniter.add_issue(
          igniter,
          Messages.base_path_mismatch_message(spec_path, prefix, operations)
        )
      end
    end

    defp prefix(spec, operations), do: Meta.base_path(spec) || BasePath.common_prefix(operations)

    defp render_layers(igniter, names, spec_path, spec, operations, prefix) do
      otp_app = Igniter.Project.Application.app_name(igniter)
      auth = Auth.strategy(spec)
      servers = Servers.resolve(spec)
      selected = BasePath.strip(operations, prefix)

      # The three layers and the auth test are `:tracked` —
      # ownership-token-aware. The external test is a `:scaffold` —
      # a user-owned file `regen` creates once and never overwrites.
      files =
        Manifest.files(names,
          otp_app: otp_app,
          auth: auth,
          servers: servers,
          prefix: prefix,
          operations: selected,
          metadata: metadata(spec_path, spec)
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
    defp accept?(igniter, location) do
      igniter.args.options[:yes] || igniter.assigns[:test_mode?] ||
        Mix.shell().yes?("hearth.regen: #{location} is hearth:collaborating — regenerate it?")
    end

    # `source` is the spec `gen` ran on (recorded in `x-hearth`), so the
    # Layer 2 moduledoc matches what gen wrote; the pruned spec path is
    # the fallback.
    defp metadata(spec_path, spec) do
      Manifest.metadata(Meta.source(spec) || spec_path, spec)
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
