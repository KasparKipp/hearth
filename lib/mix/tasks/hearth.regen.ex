defmodule Mix.Tasks.Hearth.Regen.Docs do
  @moduledoc false

  def short_doc do
    "Regenerates a Hearth integration from its pruned spec. Requires igniter to run."
  end

  def example do
    "mix hearth.regen MyApp.Integrations.Stripe"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Usage

        mix hearth.regen <Layer1Module> [--yes]

    `<Layer1Module>` is the integration's raw-client module — the one
    `mix hearth.gen` created without an `Api` suffix, e.g.
    `MyApp.Integrations.Stripe`. Every other layer is derived from it.

    Regeneration reads the integration's pruned spec at
    `priv/hearth/<integration>.yaml` (written by `mix hearth.gen`) and
    re-renders the three layers and the auth test. The external test
    is a user-owned scaffold — it is never overwritten.

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
    alias Hearth.Render.ModuleNames
    alias Hearth.Spec.Auth
    alias Hearth.Spec.BasePath
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Meta
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Servers

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [yes: :boolean],
        # Optional so a bare `mix hearth.regen` halts with a
        # task-specific message rather than Igniter's generic error.
        positional: [{:integration, optional: true}],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      case igniter.args.positional[:integration] do
        nil -> Igniter.add_issue(igniter, missing_integration_message())
        arg -> regen(igniter, arg)
      end
    end

    defp regen(igniter, arg) do
      layer1 = Module.concat(String.split(arg, "."))
      names = ModuleNames.from_layer1(layer1)
      spec_path = Manifest.pruned_spec_path(names.integration)

      with true <- Igniter.exists?(igniter, spec_path) or :missing,
           igniter = Igniter.include_existing_file(igniter, spec_path),
           {:ok, bytes} <- Content.read(igniter, spec_path),
           {:ok, spec} <- Loader.decode(bytes, :yaml) do
        render(igniter, names, spec_path, spec)
      else
        :missing ->
          Igniter.add_issue(igniter, missing_spec_message(names.integration, spec_path))

        {:error, reason} ->
          Igniter.add_issue(
            igniter,
            "hearth.regen: failed to parse #{spec_path}: #{format_reason(reason)}"
          )
      end
    end

    # The base path comes from the pruned spec's `x-hearth` block — the
    # prefix `gen` folded into Layer 1 and `config/test.exs`. Recomputing
    # it from the pruned subset can yield a longer prefix and desync
    # from that config; it is only the fallback for a spec without the
    # block. A hand-edit can add a path outside the recorded prefix —
    # halt then, rather than strip the wrong segments.
    defp render(igniter, names, spec_path, spec) do
      operations = Operation.extract(spec)
      prefix = Meta.base_path(spec) || BasePath.common_prefix(operations)

      if BasePath.prefix_of_all?(operations, prefix) do
        render_layers(igniter, names, spec_path, spec, operations, prefix)
      else
        Igniter.add_issue(igniter, base_path_mismatch_message(spec_path, prefix, operations))
      end
    end

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

      Igniter.add_notice(igniter, regen_notice(names, spec_path, Enum.reverse(results)))
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

    defp regen_notice(names, spec_path, results) do
      lines =
        Enum.map_join(results, "\n", fn {location, action} -> result_line(action, location) end)

      """
      Regenerated #{inspect(names.layer1)} from #{spec_path}.

      #{lines}

      Files with no ownership token are overwritten; `hearth:owned`
      files are skipped. Edit the pruned spec and re-run to pull in
      upstream changes.
      """
    end

    defp result_line(:regenerated, location), do: "* regenerating #{location}"
    defp result_line(:created, location), do: "* creating #{location}"
    defp result_line(:owned, location), do: "* skipping #{location} (hearth:owned)"

    defp result_line(:declined, location),
      do: "* skipping #{location} (hearth:collaborating, declined)"

    defp result_line(:kept, location), do: "* keeping #{location} (user-owned scaffold)"

    defp result_line(:unreadable, location),
      do: "* skipping #{location} (could not read it to check its ownership token)"

    defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
    defp format_reason(reason), do: inspect(reason)

    defp missing_integration_message do
      """
      hearth.regen: name the integration's Layer 1 module.

        mix hearth.regen MyApp.Integrations.Stripe

      That is the raw-client module `mix hearth.gen` created (no `Api`
      suffix). Every other layer is derived from it.
      """
    end

    defp base_path_mismatch_message(spec_path, prefix, operations) do
      outside =
        operations
        |> Enum.reject(&BasePath.prefix_of_all?([&1], prefix))
        |> Enum.map_join("\n", &"  * #{&1.path}")

      """
      hearth.regen: #{spec_path} has paths outside its recorded base path #{prefix}:

      #{outside}

      The base path is folded into the generated client's base URL and
      into `config/test.exs`. Either move these paths under #{prefix},
      or lower `x-hearth.base_path` in #{spec_path} to a prefix every
      path shares — and update the `base_url` config to match.
      """
    end

    defp missing_spec_message(integration, spec_path) do
      """
      hearth.regen: no pruned spec for #{integration} at #{spec_path}.

      `mix hearth.regen` regenerates from the pruned spec that
      `mix hearth.gen` writes. Generate the integration first:

        mix hearth.gen <source> --integration #{integration}
      """
    end
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
