defmodule Hearth.Spec.Swagger do
  @moduledoc false

  # Swagger 2.0 → OpenAPI 3.0, in memory, right after a source is
  # decoded — so overrides, selection, pruning, auth, rendering and
  # drift only ever see OpenAPI 3, and the pruned spec is OpenAPI 3.
  #
  #   * `host` / `basePath` / `schemes` → `servers` (no host: a relative
  #     server with the base path; `Hearth.Spec.Servers` gives it a
  #     placeholder host);
  #   * `definitions` / `parameters` / `responses` /
  #     `securityDefinitions` → `components`, with every `$ref`
  #     rewritten;
  #   * a `body` parameter → the operation's `requestBody`, one entry
  #     per consumed media type; `formData` parameters → a form
  #     `requestBody`; other parameters get their type as a `schema`;
  #   * a response `schema` → `content`, per produced media type;
  #   * schema keywords Swagger spells differently (`x-nullable`,
  #     `type: file`, a string `discriminator`).
  #
  # Pure.

  @methods ~w(get put post delete options head patch)
  @schema_keys ~w(type format items enum default maximum exclusiveMaximum minimum
                  exclusiveMinimum maxLength minLength pattern maxItems minItems
                  uniqueItems multipleOf)
  @dropped ~w(swagger host basePath schemes consumes produces paths definitions
              parameters responses securityDefinitions)
  @json ["application/json"]

  @spec swagger?(term()) :: boolean()
  def swagger?(spec), do: is_map(spec) and spec["swagger"] in ["2.0", "2"]

  # The spec as OpenAPI 3: converted when it's Swagger 2.0, else as is.
  @spec normalize(term()) :: term()
  def normalize(spec), do: if(swagger?(spec), do: to_openapi(spec), else: spec)

  @spec to_openapi(map()) :: map()
  def to_openapi(spec) do
    ctx = %{
      consumes: spec["consumes"] || @json,
      produces: spec["produces"] || @json,
      parameters: spec["parameters"] || %{}
    }

    spec
    |> Map.drop(@dropped)
    |> Map.put("openapi", "3.0.3")
    |> put_present("servers", servers(spec))
    |> Map.put(
      "paths",
      Map.new(spec["paths"] || %{}, fn {path, item} -> {path, path_item(item, ctx)} end)
    )
    |> put_present("components", components(spec, ctx))
    |> rewrite_refs()
  end

  defp servers(%{"host" => host} = spec) when is_binary(host) do
    base = base_path(spec)
    for scheme <- spec["schemes"] || ["https"], do: %{"url" => "#{scheme}://#{host}#{base}"}
  end

  defp servers(spec) do
    case base_path(spec) do
      "" -> []
      base -> [%{"url" => base}]
    end
  end

  defp base_path(spec), do: String.trim_trailing(spec["basePath"] || "", "/")

  defp components(spec, ctx) do
    parameters =
      for {name, param} <- ctx.parameters,
          param["in"] not in ["body", "formData"],
          into: %{},
          do: {name, parameter(param)}

    %{}
    |> put_present(
      "schemas",
      Map.new(spec["definitions"] || %{}, fn {k, v} -> {k, schema(v)} end)
    )
    |> put_present("parameters", parameters)
    |> put_present(
      "responses",
      Map.new(spec["responses"] || %{}, fn {k, v} -> {k, response(v, ctx.produces)} end)
    )
    |> put_present(
      "securitySchemes",
      Map.new(spec["securityDefinitions"] || %{}, fn {k, v} -> {k, security_scheme(v)} end)
    )
  end

  # Body parameters declared on the path item move into each operation.
  defp path_item(item, ctx) when is_map(item) do
    {bodies, params} =
      item |> Map.get("parameters", []) |> deref(ctx) |> Enum.split_with(&body?/1)

    item
    |> Map.new(fn
      {method, op} when method in @methods and is_map(op) -> {method, operation(op, bodies, ctx)}
      other -> other
    end)
    |> Map.delete("parameters")
    |> put_present("parameters", Enum.map(params, &parameter/1))
  end

  defp path_item(item, _ctx), do: item

  defp operation(op, path_bodies, ctx) do
    {bodies, params} = op |> Map.get("parameters", []) |> deref(ctx) |> Enum.split_with(&body?/1)
    bodies = if bodies == [], do: path_bodies, else: bodies
    produces = op["produces"] || ctx.produces

    op
    |> Map.drop(~w(consumes produces schemes parameters))
    |> put_present("parameters", Enum.map(params, &parameter/1))
    |> put_present("requestBody", request_body(bodies, op["consumes"] || ctx.consumes))
    |> Map.update("responses", %{}, fn responses ->
      Map.new(responses, fn {code, r} -> {code, response(r, produces)} end)
    end)
  end

  # A `$ref` to a body or formData parameter is inlined — those have no
  # OpenAPI 3 parameter to point at.
  defp deref(params, ctx) do
    Enum.map(List.wrap(params), fn
      %{"$ref" => "#/parameters/" <> name} = ref ->
        target = ctx.parameters[name]
        if body?(target || %{}), do: target, else: ref

      param ->
        param
    end)
  end

  defp body?(param), do: param["in"] in ["body", "formData"]

  defp request_body([], _consumes), do: nil

  defp request_body([%{"in" => "body"} = body | _], consumes) do
    %{"content" => Map.new(consumes, &{&1, %{"schema" => schema(body["schema"] || %{})}})}
    |> put_present("required", body["required"] == true)
    |> put_present("description", body["description"])
  end

  defp request_body(fields, consumes) do
    fields = Enum.filter(fields, &(&1["in"] == "formData"))
    multipart? = "multipart/form-data" in consumes or Enum.any?(fields, &(&1["type"] == "file"))
    media = if multipart?, do: "multipart/form-data", else: "application/x-www-form-urlencoded"
    required = for field <- fields, field["required"] == true, do: field["name"]

    properties =
      Map.new(fields, fn field ->
        {field["name"], field |> typed() |> put_present("description", field["description"])}
      end)

    form = put_present(%{"type" => "object", "properties" => properties}, "required", required)

    put_present(%{"content" => %{media => %{"schema" => form}}}, "required", required != [])
  end

  defp parameter(%{"$ref" => _} = ref), do: ref

  defp parameter(param) do
    param
    |> Map.drop(["collectionFormat", "x-example" | @schema_keys])
    |> Map.put("schema", typed(param))
    |> put_present("example", param["x-example"])
    |> Map.merge(collection_style(param["collectionFormat"]))
  end

  defp collection_style("multi"), do: %{"explode" => true}
  defp collection_style("csv"), do: %{"explode" => false}
  defp collection_style("ssv"), do: %{"style" => "spaceDelimited", "explode" => false}
  defp collection_style("pipes"), do: %{"style" => "pipeDelimited", "explode" => false}
  defp collection_style(_format), do: %{}

  # A parameter's or header's type keywords, as a schema.
  defp typed(object), do: object |> Map.take(@schema_keys) |> schema()

  defp response(%{"$ref" => _} = ref, _produces), do: ref

  defp response(response, produces) do
    content =
      case response["schema"] do
        nil ->
          nil

        schema ->
          Map.new(produces, fn media ->
            example = get_in(response, ["examples", media])
            {media, put_present(%{"schema" => schema(schema)}, "example", example)}
          end)
      end

    headers =
      Map.new(response["headers"] || %{}, fn {name, header} ->
        {name, header |> Map.take(["description"]) |> Map.put("schema", typed(header))}
      end)

    response
    |> Map.drop(~w(schema examples headers))
    |> Map.put_new("description", "")
    |> put_present("content", content)
    |> put_present("headers", headers)
  end

  defp security_scheme(%{"type" => "basic"} = s),
    do: put_present(%{"type" => "http", "scheme" => "basic"}, "description", s["description"])

  defp security_scheme(%{"type" => "oauth2"} = s) do
    {flow, keys} =
      case s["flow"] do
        "implicit" -> {"implicit", ~w(authorizationUrl)}
        "password" -> {"password", ~w(tokenUrl)}
        "application" -> {"clientCredentials", ~w(tokenUrl)}
        _access_code -> {"authorizationCode", ~w(authorizationUrl tokenUrl)}
      end

    settings = s |> Map.take(keys) |> Map.put("scopes", s["scopes"] || %{})

    put_present(
      %{"type" => "oauth2", "flows" => %{flow => settings}},
      "description",
      s["description"]
    )
  end

  defp security_scheme(scheme), do: scheme

  # Swagger-only schema keywords, everywhere in a schema.
  defp schema(map) when is_map(map) do
    map
    |> Map.new(fn
      {"x-nullable", value} -> {"nullable", value}
      {"discriminator", name} when is_binary(name) -> {"discriminator", %{"propertyName" => name}}
      {key, value} -> {key, schema(value)}
    end)
    |> Map.delete("collectionFormat")
    |> file_type()
  end

  defp schema(list) when is_list(list), do: Enum.map(list, &schema/1)
  defp schema(value), do: value

  defp file_type(%{"type" => "file"} = schema),
    do: Map.merge(schema, %{"type" => "string", "format" => "binary"})

  defp file_type(schema), do: schema

  @refs [
    {"#/definitions/", "#/components/schemas/"},
    {"#/parameters/", "#/components/parameters/"},
    {"#/responses/", "#/components/responses/"}
  ]

  defp rewrite_refs(%{"$ref" => ref} = map) when is_binary(ref) do
    rewritten =
      Enum.find_value(@refs, ref, fn {from, to} ->
        if String.starts_with?(ref, from), do: to <> String.replace_prefix(ref, from, "")
      end)

    Map.put(map, "$ref", rewritten)
  end

  defp rewrite_refs(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, rewrite_refs(v)} end)
  defp rewrite_refs(list) when is_list(list), do: Enum.map(list, &rewrite_refs/1)
  defp rewrite_refs(value), do: value

  defp put_present(map, _key, value) when value in [nil, false, [], %{}], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
