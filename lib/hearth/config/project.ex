if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Config.Project do
    @moduledoc false

    # Reads and writes the project's `.hearth.exs` through Igniter, so
    # test fixtures and real files take the same path and every write
    # shows up in Igniter's diff. Writes edit the keyword list in place
    # with Sourceror, keeping the user's comments and other entries.
    # See `Hearth.Config` for the file's shape.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config
    alias Hearth.Fs.Content

    @spec read(Igniter.t()) :: {:ok, Igniter.t(), Config.integrations()} | {:error, String.t()}
    def read(igniter) do
      path = Config.path()
      igniter = Igniter.include_existing_file(igniter, path)

      if Igniter.exists?(igniter, path) do
        with {:ok, content} <- Content.read(igniter, path),
             {:ok, integrations} <- Config.parse(content) do
          {:ok, igniter, integrations}
        else
          {:error, message} when is_binary(message) -> {:error, message}
          {:error, _reason} -> {:error, "could not read #{path}"}
        end
      else
        {:ok, igniter, []}
      end
    end

    # Sets the integration's whole entry, creating `.hearth.exs` from
    # the template when it's missing.
    @spec put_integration(Igniter.t(), atom(), Config.entry()) :: Igniter.t()
    def put_integration(igniter, key, entry) do
      put(igniter, [:integrations, key], entry)
    end

    @spec put_module(Igniter.t(), atom(), module()) :: Igniter.t()
    def put_module(igniter, key, module) do
      put(igniter, [:integrations, key, :module], module)
    end

    defp put(igniter, keys, value) do
      quoted = value |> Macro.escape() |> Sourceror.to_string() |> Sourceror.parse_string!()

      igniter
      |> Igniter.create_or_update_elixir_file(Config.path(), Config.template(), &{:ok, &1})
      |> Igniter.update_elixir_file(Config.path(), fn zipper ->
        rightmost = Igniter.Code.Common.rightmost(zipper)

        if Igniter.Code.List.list?(rightmost) do
          Igniter.Code.Keyword.put_in_keyword(rightmost, keys, quoted)
        else
          {:warning,
           "Could not update #{Config.path()}: it doesn't end in a keyword list. " <>
             "Set #{Enum.map_join(keys, " → ", &inspect/1)} to #{inspect(value)} by hand."}
        end
      end)
    end
  end
end
