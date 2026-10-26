defmodule Hearth.Render.PrefixedIds do
  @moduledoc false

  # The code `prefixed_ids:` adds to the three layers. `prefixed` is
  # `%{functions:, resources:, base_path:}` — the entry's functions, the
  # `Hearth.Spec.PrefixedIds.resolve/2` resources, and the base path
  # Layer 1 already folds into its base URL. `nil` renders nothing.
  #
  #   * Layer 1 — `parse_url/1`, which `request/2` runs every URL
  #     through: `"cus_123"` → `"/customers/cus_123"`; other URLs pass
  #   * Layer 2 — a callback and a dispatcher per function
  #   * Layer 3 — each function is `request(id, …)` with its method

  @return_type "{:ok, Req.Response.t()} | {:error, Exception.t()}"

  @spec layer1(map() | nil) :: String.t()
  def layer1(nil), do: ""

  def layer1(%{resources: resources, base_path: base_path}) do
    clauses =
      for resource <- resources do
        ~s|defp parse_url("#{resource.prefix}_" <> _ = id), do: #{path_literal(resource.path, base_path)}|
      end

    """


    # A type-prefixed id stands for its resource's path:
    # `"#{hd(resources).prefix}_123"` → `#{example(hd(resources), base_path)}`. Anything after
    # the id comes along; any other URL passes through.
    #{Enum.join(clauses, "\n")}
    defp parse_url(url), do: url\
    """
  end

  # `request/2` and `request!/2`, running the URL through `parse_url/1`.
  @spec request_funs(map() | nil) :: String.t() | nil
  def request_funs(nil), do: nil

  def request_funs(_prefixed) do
    """
    @doc \"\"\"
    Performs a request — returns `{:ok, response}` or `{:error, exception}`.
    `url` may be a type-prefixed id, which stands for its resource's path.
    \"\"\"
    def request(url, opts \\\\ []), do: Req.request(new(url: parse_url(url)), opts)

    @doc "Like `request/2`, but raises on error."
    def request!(url, opts \\\\ []), do: Req.request!(new(url: parse_url(url)), opts)
    """
  end

  @spec layer2(map() | nil) :: String.t()
  def layer2(nil), do: ""

  def layer2(%{functions: functions, resources: resources}) do
    Enum.map_join(functions, "", fn {name, method} ->
      prefixes = works_for(resources, method)

      """


      @callback #{name}(id :: String.t(), opts :: keyword()) :: #{@return_type}

      @doc \"\"\"
      `#{method |> Atom.to_string() |> String.upcase()}` the resource a type-prefixed id names —
      `#{name}("#{List.first(prefixes) || "id"}_123")`. Works for: #{Enum.join(prefixes, ", ")}.
      \"\"\"
      def #{name}(id, opts \\\\ []), do: impl().#{name}(id, opts)\
      """
    end)
  end

  @spec layer3(map() | nil, String.t()) :: String.t()
  def layer3(nil, _client), do: ""

  def layer3(%{functions: functions}, client) do
    Enum.map_join(functions, "", fn {name, method} ->
      opts = if method == :get, do: "opts", else: "[method: #{inspect(method)}] ++ opts"

      """


      @impl true
      def #{name}(id, opts \\\\ []), do: #{client}.request(id, #{opts})\
      """
    end)
  end

  defp works_for(resources, method), do: for(r <- resources, method in r.methods, do: r.prefix)

  # `/v1/customers/{customer}` under base path `/v1` → the literal
  # `"/customers/#{id}"`.
  defp path_literal(path, base_path) do
    relative = if base_path != "", do: String.replace_prefix(path, base_path, ""), else: path
    ~s|"#{Regex.replace(~r/\{[^}]+\}/, relative, "\#{id}")}"|
  end

  defp example(resource, base_path) do
    path_literal(resource.path, base_path) |> String.replace("\#{id}", "#{resource.prefix}_123")
  end
end
