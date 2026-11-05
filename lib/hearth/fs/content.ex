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

    alias Hearth.Spec.Loader

    @spec read(Igniter.t(), Path.t()) :: {:ok, binary()} | {:error, Rewrite.Error.t()}
    def read(igniter, path) do
      with {:ok, source} <- Rewrite.source(igniter.rewrite, project_path(path)) do
        {:ok, Rewrite.Source.get(source, :content)}
      end
    end

    # Sniff format → existence check → read → decode a spec file. The
    # returned igniter has the file in its Rewrite. Callers word the
    # errors for their task.
    @spec read_spec(Igniter.t(), Path.t()) ::
            {:ok, Igniter.t(), term()} | {:error, :unsupported | :missing | {:decode, term()}}
    def read_spec(igniter, path) do
      path = project_path(path)

      with format when format in [:yaml, :json] <- Loader.sniff(path),
           true <- Igniter.exists?(igniter, path) or :missing,
           igniter = Igniter.include_existing_file(igniter, path),
           {:ok, bytes} <- read(igniter, path),
           {:ok, spec} <- Loader.decode(bytes, format) do
        {:ok, igniter, spec}
      else
        :unknown -> {:error, :unsupported}
        :missing -> {:error, :missing}
        {:error, reason} -> {:error, {:decode, reason}}
      end
    end

    # A path as Igniter keys its files: relative to the project, through
    # `..` when outside it (`Igniter.exists?/2` does the same). An
    # absolute path must never reach the Rewrite: before writing,
    # Igniter's format step globs `<first segment>/**/.formatter.exs` for
    # every file in it, skipping only `..`, so `/…` searches the whole
    # disk.
    @spec project_path(Path.t()) :: Path.t()
    def project_path(path), do: Path.relative_to_cwd(path, force: true)
  end
end
