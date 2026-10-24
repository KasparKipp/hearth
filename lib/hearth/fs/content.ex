if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Fs.Content do
    @moduledoc false

    # Reads a file's content through Igniter's Rewrite layer, so test
    # fixtures (`test_project(files: …)`) and real files take the same
    # path. The file must already be in the Rewrite — call
    # `Igniter.include_existing_file/2` first for a file on disk.
    #
    # Guarded like the Mix tasks: Igniter, and Rewrite with it, is an
    # optional dependency.

    @spec read(Igniter.t(), Path.t()) :: {:ok, binary()} | {:error, Rewrite.Error.t()}
    def read(igniter, path) do
      with {:ok, source} <- Rewrite.source(igniter.rewrite, path) do
        {:ok, Rewrite.Source.get(source, :content)}
      end
    end
  end
end
