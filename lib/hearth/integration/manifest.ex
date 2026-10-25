defmodule Hearth.Integration.Manifest do
  @moduledoc false

  # The files a generated integration consists of — shared by
  # `mix hearth.gen` (which creates them) and `mix hearth.regen` (which
  # refreshes them), so the two cannot drift apart. Pure: rendering
  # only, no I/O.
  #
  # Each entry carries:
  #
  #   * `:kind` — `:source_folder` (→ `lib/`) or `:test` (→ `test/`,
  #     routed by the `Test` suffix), for
  #     `Igniter.Project.Module.proper_location/3`;
  #   * `:policy` — `:tracked` (Hearth-owned: regenerated, subject to
  #     ownership tokens) or `:scaffold` (user-owned: created once,
  #     never overwritten);
  #   * `:label` — the one-line description in gen's notice.

  alias Hearth.Gen.Messages
  alias Hearth.Render

  @type kind :: :source_folder | :test

  @type entry :: %{
          module: module(),
          content: String.t(),
          kind: kind(),
          policy: :tracked | :scaffold,
          label: String.t()
        }

  # `names` is the map `Hearth.Render.ModuleNames.from_layer1/1` returns.
  @spec modules(map()) :: [{module(), kind()}]
  def modules(names) do
    [
      {names.layer1, :source_folder},
      {names.layer2, :source_folder},
      {names.layer3, :source_folder},
      {names.layer1_test, :test},
      {names.external_test, :test}
    ]
  end

  # Renders every file. `opts`: `:otp_app`, `:auth` (a
  # `Hearth.Spec.Auth.strategy/1` value), `:servers` (a
  # `Hearth.Spec.Servers.resolve/1` result), `:prefix` (the base path),
  # `:operations` (already prefix-stripped), and `:metadata` (for the
  # Layer 2 moduledoc — see `metadata/2`).
  @spec files(map(), keyword()) :: [entry()]
  def files(names, opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    auth = Keyword.fetch!(opts, :auth)
    servers = Keyword.fetch!(opts, :servers)
    prefix = Keyword.fetch!(opts, :prefix)
    operations = Keyword.fetch!(opts, :operations)
    count = length(operations)

    [
      entry(
        names.layer1,
        Render.Layer1.render(names.layer1, otp_app, servers.default, prefix, auth),
        :tracked,
        "raw Req client"
      ),
      entry(
        names.layer2,
        Render.Layer2.render(names.layer2, operations,
          metadata: Keyword.fetch!(opts, :metadata),
          otp_app: otp_app
        ),
        :tracked,
        "behaviour, #{count} #{Messages.pluralize("callback", count)}"
      ),
      entry(
        names.layer3,
        Render.Layer3.render(names.layer3, names.layer2, names.layer1, operations),
        :tracked,
        "Req implementation, #{count} #{Messages.pluralize("function", count)}"
      ),
      entry(
        names.layer1_test,
        Render.Tests.layer1(names.layer1_test, names.layer1, otp_app, auth),
        :tracked,
        "Layer 1 auth test"
      ),
      entry(
        names.external_test,
        Render.Tests.external(
          names.external_test,
          names.layer2,
          names.layer1,
          otp_app,
          auth,
          operations
        ),
        :scaffold,
        "external integration test"
      )
    ]
    |> Enum.zip(modules(names))
    |> Enum.map(fn {entry, {_module, kind}} -> Map.put(entry, :kind, kind) end)
  end

  # The integration's pruned spec — its versioned source of truth.
  @spec pruned_spec_path(String.t()) :: String.t()
  def pruned_spec_path(integration) do
    "priv/hearth/#{Macro.underscore(integration)}.yaml"
  end

  # Metadata for the Layer 2 moduledoc footer: the source the spec came
  # from, plus its `info` fields.
  @spec metadata(String.t(), map()) :: map()
  def metadata(source, spec) do
    %{
      source: source,
      title: get_in(spec, ["info", "title"]),
      version: get_in(spec, ["info", "version"]),
      openapi: spec["openapi"],
      description: get_in(spec, ["info", "description"])
    }
  end

  defp entry(module, content, policy, label) do
    %{module: module, content: content, policy: policy, label: label}
  end
end
