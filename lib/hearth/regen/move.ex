if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Regen.Move do
    @moduledoc false

    # `mix hearth.regen <name> --module <NewLayer1> [--remove-old]`:
    # regenerates one integration into a new namespace and retires the
    # old module — listing its files for the user to delete, or with
    # `--remove-old` removing them and their config. `old` and `new` are
    # `Hearth.Render.ModuleNames.from_layer1/1` maps. Rendering and
    # argument checks stay in the task, which passes `ctx`:
    #
    #   * `:key`     — the integration's `.hearth.exs` key
    #   * `:render`  — renders the integration under `new` (igniter → igniter)
    #   * `:wiring`  — the `Hearth.Gen.Patches.wire/2` context for `new`
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config.Project
    alias Hearth.Fs.Content
    alias Hearth.Fs.Ownership
    alias Hearth.Gen.Patches
    alias Hearth.Integration.Manifest
    alias Hearth.Regen.Messages

    # Renders the integration into the new module (via `ctx.render`),
    # points its `.hearth.exs` entry at it, and wires its mock and config the way
    # `gen` does. Like `gen`, it only creates: it halts if any of the new
    # module's files exist. The old module is then retired by `retire/4`.
    @spec run(Igniter.t(), map(), map(), map()) :: Igniter.t()
    def run(igniter, old, new, ctx) do
      %{key: key, render: render, wiring: wiring} = ctx

      case existing_files(igniter, new) do
        [] ->
          igniter
          |> render.()
          |> Project.put_module(key, new.layer1)
          |> Patches.wire(wiring)
          |> retire(old, new)

        existing ->
          paths = Enum.map(existing, &elem(&1, 0))
          Igniter.add_issue(igniter, Messages.target_exists_message(new.layer1, paths))
      end
    end

    # Without `--remove-old` the old module stays and the notice lists
    # its files for the user to delete.
    defp retire(igniter, old, new) do
      old_files = existing_files(igniter, old)

      if igniter.args.options[:remove_old] do
        {igniter, results} = remove_old(igniter, old, old_files)
        Igniter.add_notice(igniter, Messages.removed_notice(old, new, results))
      else
        paths = Enum.map(old_files, &elem(&1, 0))
        Igniter.add_notice(igniter, Messages.moved_notice(old, new, paths))
      end
    end

    # `--remove-old`: delete the old module's files and every config
    # entry `gen` wrote for it. Files the user claimed — an ownership
    # token, or the external test scaffold — are kept and listed.
    # Ownership fails closed: an unreadable file is kept too.
    defp remove_old(igniter, old, old_files) do
      {igniter, results} =
        Enum.reduce(old_files, {igniter, []}, fn {path, policy}, {acc, results} ->
          case claim(acc, path, policy) do
            {acc, :none} -> {Igniter.rm(acc, path), [{path, :removed} | results]}
            {acc, claim} -> {acc, [{path, claim} | results]}
          end
        end)

      otp_app = Igniter.Project.Application.app_name(igniter)
      {Patches.unwire(igniter, otp_app, old), Enum.reverse(results)}
    end

    defp claim(igniter, _path, :scaffold), do: {igniter, :scaffold}

    defp claim(igniter, path, :tracked) do
      igniter = Igniter.include_existing_file(igniter, path)

      case Content.read(igniter, path) do
        {:ok, existing} -> {igniter, Ownership.classify(existing)}
        {:error, _reason} -> {igniter, :unreadable}
      end
    end

    defp existing_files(igniter, names) do
      names
      |> Manifest.modules()
      |> Enum.map(fn {module, kind, policy} ->
        {Igniter.Project.Module.proper_location(igniter, module, kind), policy}
      end)
      |> Enum.filter(fn {path, _policy} -> Igniter.exists?(igniter, path) end)
    end
  end
end
