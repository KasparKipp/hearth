if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Integration.Build do
    @moduledoc false

    # Runs an entry's `build:` — a Mix command line, like an alias step
    # (`"acme.spec --out priv/specs/acme.yaml"`) — before its source is
    # read, so a spec built from another format is fresh when `gen`,
    # `regen --sync` and `diff` load it. Each command runs once per run
    # (the `:hearth_built` igniter assign), however many entries name it.
    #
    # A task that raises or exits non-zero is an error with its message,
    # and the caller stops before reading the source. The
    # `:hearth_build` assign — `fn igniter, task, args -> {:ok, igniter}
    # | {:error, message}` — stands in for Mix, which tests use: Igniter's
    # test mode can't see what a real task writes to disk.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config

    @type error :: {:build, String.t(), String.t()}

    @spec run(Igniter.t(), Config.entry()) :: {:ok, Igniter.t()} | {:error, error()}
    def run(igniter, entry) do
      case Config.build(entry) do
        nil -> {:ok, igniter}
        {command, task, args} -> run_once(igniter, command, task, args)
      end
    end

    defp run_once(igniter, command, task, args) do
      built = igniter.assigns[:hearth_built] || MapSet.new()

      if MapSet.member?(built, command) do
        {:ok, igniter}
      else
        runner = igniter.assigns[:hearth_build] || (&run_task/3)

        case runner.(igniter, task, args) do
          {:ok, igniter} ->
            {:ok, Igniter.assign(igniter, :hearth_built, MapSet.put(built, command))}

          {:error, message} ->
            {:error, {:build, command, message}}
        end
      end
    end

    # `rerun`, so a task the project already ran (or a second command
    # naming the same task) runs again.
    defp run_task(igniter, task, args) do
      Mix.Task.rerun(task, args)
      {:ok, igniter}
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, {:shutdown, 0} ->
        {:ok, igniter}

      :exit, {:shutdown, status} when is_integer(status) ->
        {:error, "it exited with status #{status}"}

      :exit, reason ->
        {:error, "it exited: #{inspect(reason)}"}
    end
  end
end
