defmodule Hearth.Integration.ManifestTest do
  use ExUnit.Case, async: true

  alias Hearth.Integration.Manifest
  alias Hearth.Render.ModuleNames
  alias Hearth.Spec.Loader
  alias Hearth.Spec.Operation
  alias Hearth.Spec.Servers

  @names ModuleNames.from_layer1(Test.Integrations.Petstore)

  defp files do
    {:ok, spec} =
      "test/fixtures/specs/petstore-3.0.yaml" |> File.read!() |> Loader.decode(:yaml)

    Manifest.files(@names,
      otp_app: :test,
      auth: :none,
      servers: Servers.resolve(spec),
      prefix: "",
      operations: Operation.extract(spec),
      metadata: %{}
    )
  end

  describe "modules/1" do
    test "lists every generated module with its location kind" do
      assert Manifest.modules(@names) == [
               {Test.Integrations.Petstore, :source_folder},
               {Test.Integrations.Petstore.PetstoreApi, :source_folder},
               {Test.Integrations.Petstore.PetstoreApi.Req, :source_folder},
               {Test.Integrations.PetstoreTest, :test},
               {Test.Integrations.PetstoreExternalTest, :test}
             ]
    end
  end

  describe "files/2" do
    test "renders one entry per module, in modules/1 order" do
      assert Enum.map(files(), &{&1.module, &1.kind}) == Manifest.modules(@names)
    end

    test "the external test is a user-owned scaffold; the rest are tracked" do
      assert Enum.map(files(), & &1.policy) ==
               [:tracked, :tracked, :tracked, :tracked, :scaffold]
    end

    test "labels describe each file, with operation counts" do
      assert Enum.map(files(), & &1.label) == [
               "raw Req client",
               "behaviour, 3 callbacks",
               "Req implementation, 3 functions",
               "Layer 1 auth test",
               "external integration test"
             ]
    end

    test "each entry's content defines its module" do
      for entry <- files() do
        assert entry.content =~ "defmodule #{inspect(entry.module)} do"
      end
    end
  end

  describe "pruned_spec_path/1" do
    test "is priv/hearth/<snake_case integration>.yaml" do
      assert Manifest.pruned_spec_path("SendGrid") == "priv/hearth/send_grid.yaml"
    end
  end

  describe "metadata/2" do
    test "takes the source plus the spec's info fields" do
      spec = %{"openapi" => "3.1.0", "info" => %{"title" => "T", "version" => "2"}}

      assert Manifest.metadata("priv/specs/t.yaml", spec) == %{
               source: "priv/specs/t.yaml",
               title: "T",
               version: "2",
               openapi: "3.1.0",
               description: nil
             }
    end
  end
end
