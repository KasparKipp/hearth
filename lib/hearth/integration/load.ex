if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Integration.Load do
    @moduledoc false

    # Turns any source into a decoded spec — what `gen`, `regen --sync`
    # and `diff` share:
    #
    #   * a file path — read through Igniter's Rewrite
    #   * an http(s) URL — fetched with `Hearth.Spec.Fetcher` (or the
    #     `:hearth_fetch` igniter assign, which tests use to stub the
    #     network); the format comes from the URL's extension, or the
    #     content when it has none
    #   * a registry shortcut — `name@version` looked up in the project's
    #     `.hearth.exs` registry, then Hearth's built-in one, and loaded
    #     from the location it points at
    #
    # A Swagger 2.0 spec is converted to OpenAPI 3 (`Hearth.Spec.Swagger`)
    # before anything sees it; `converted_from` says so. A `sources:`
    # list (`[items: "…", orders: "…"]`) loads each source that way and
    # merges them (`Hearth.Spec.Merge`); `sha256` is then one checksum
    # per source, `splits` the components the merge prefixed per source
    # (`keep` pins plain names — `overrides: [shared: …]`). Errors are
    # reasons for the callers to word.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Fs.Content
    alias Hearth.Registry
    alias Hearth.Spec.Fetcher
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Merge
    alias Hearth.Spec.Source
    alias Hearth.Spec.Swagger

    @type loaded :: %{
            spec: map(),
            bytes: binary(),
            location: String.t(),
            entry: Registry.entry() | nil,
            converted_from: String.t() | nil,
            sha256: String.t() | [{atom(), String.t()}],
            splits: [Merge.component()]
          }

    @type reason ::
            :unsupported
            | :missing
            | {:decode, term()}
            | {:fetch, String.t(), term()}
            | {:registry, Registry.lookup_error()}
            | {:invalid, String.t()}
            | {:in_source, String.t(), term()}
            | {:merge, String.t()}

    @spec load(Igniter.t(), Hearth.Config.source(), map(), map()) ::
            {:ok, Igniter.t(), loaded()} | {:error, reason()}
    def load(igniter, source, registry \\ %{}, keep \\ %{})

    def load(igniter, [{_key, _source} | _] = sources, registry, keep) do
      with {:ok, igniter, loaded} <- load_each(igniter, sources, registry),
           {:ok, spec, splits} <- merge(loaded, keep) do
        {:ok, igniter,
         %{
           spec: spec,
           bytes: nil,
           location: Hearth.Config.source_label(sources),
           entry: nil,
           converted_from: Enum.find_value(loaded, fn {_key, l} -> l.converted_from end),
           sha256: Enum.map(loaded, fn {key, l} -> {key, l.sha256} end),
           splits: splits
         }}
      end
    end

    def load(igniter, source, registry, _keep) do
      with {:ok, igniter, loaded} <- resolve(igniter, source, registry) do
        {:ok, igniter,
         loaded |> normalize() |> Map.merge(%{sha256: sha256(loaded.bytes), splits: []})}
      end
    end

    @spec sha256(binary()) :: String.t()
    def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    defp load_each(igniter, sources, registry) do
      Enum.reduce_while(sources, {:ok, igniter, []}, fn {key, source}, {:ok, igniter, acc} ->
        case load(igniter, source, registry) do
          {:ok, igniter, loaded} -> {:cont, {:ok, igniter, acc ++ [{key, loaded}]}}
          {:error, reason} -> {:halt, {:error, {:in_source, source, reason}}}
        end
      end)
    end

    defp merge(loaded, keep) do
      case Merge.merge(Enum.map(loaded, fn {key, l} -> {key, l.spec} end), keep) do
        {:ok, spec, splits} -> {:ok, spec, splits}
        {:error, message} -> {:error, {:merge, message}}
      end
    end

    defp resolve(igniter, source, registry) do
      case Source.resolve(source) do
        {:registry, name} ->
          with {:ok, entry} <- lookup(name, registry),
               {:ok, igniter, loaded} <- location(igniter, entry.location) do
            {:ok, igniter, %{loaded | entry: entry}}
          end

        _location ->
          location(igniter, source)
      end
    end

    defp normalize(%{spec: spec} = loaded) do
      if Swagger.swagger?(spec),
        do: %{loaded | spec: Swagger.to_openapi(spec), converted_from: "Swagger 2.0"},
        else: loaded
    end

    defp lookup(name, registry) do
      case Registry.lookup(name, registry) do
        {:ok, entry} -> {:ok, entry}
        {:error, error} -> {:error, {:registry, error}}
      end
    end

    # A registry entry points at a location, never at another shortcut.
    defp location(igniter, location) do
      case Source.resolve(location) do
        {:file, path} -> file(igniter, path)
        {:url, url} -> url(igniter, url)
        {:registry, _name} -> {:error, {:invalid, location}}
        {:error, message} -> {:error, {:invalid, message}}
      end
    end

    defp file(igniter, path) do
      with {:ok, igniter, spec} <- Content.read_spec(igniter, path),
           {:ok, bytes} <- Content.read(igniter, path) do
        {:ok, igniter,
         %{spec: spec, bytes: bytes, location: path, entry: nil, converted_from: nil}}
      end
    end

    defp url(igniter, url) do
      fetch = igniter.assigns[:hearth_fetch] || default_fetch(igniter)

      with {:ok, bytes} <- fetched(fetch.(url), url),
           {:ok, spec} <- decode(bytes, format(url, bytes)) do
        {:ok, igniter,
         %{spec: spec, bytes: bytes, location: url, entry: nil, converted_from: nil}}
      end
    end

    # Igniter's test mode never touches the network: a test that loads
    # a URL stubs it with the `:hearth_fetch` assign.
    defp default_fetch(igniter) do
      if igniter.assigns[:test_mode?],
        do: fn _url -> {:error, :network_disabled_in_test_mode} end,
        else: &Fetcher.fetch/1
    end

    defp fetched({:ok, bytes}, _url), do: {:ok, bytes}
    defp fetched({:error, reason}, url), do: {:error, {:fetch, url, reason}}

    defp format(url, bytes) do
      case Loader.sniff(url) do
        :unknown ->
          if String.starts_with?(String.trim_leading(bytes), ["{", "["]), do: :json, else: :yaml

        format ->
          format
      end
    end

    defp decode(bytes, format) do
      case Loader.decode(bytes, format) do
        {:ok, spec} -> {:ok, spec}
        {:error, reason} -> {:error, {:decode, reason}}
      end
    end
  end
end
