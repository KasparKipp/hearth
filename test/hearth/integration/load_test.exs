defmodule Hearth.Integration.LoadTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Hearth.Integration.Load

  @yaml "openapi: 3.0.0\ninfo: {title: Y, version: '1'}\npaths: {}\n"
  @json ~s|{"openapi": "3.1.0", "info": {"title": "J", "version": "1"}, "paths": {}}|

  # Stubs the network: `url → {:ok, body} | {:error, reason}`.
  defp with_fetch(igniter, responses) do
    Igniter.assign(igniter, :hearth_fetch, fn url ->
      Map.get(responses, url, {:error, {:status, 404}})
    end)
  end

  test "a file path" do
    igniter = test_project(files: %{"priv/specs/a.yaml" => @yaml})

    assert {:ok, _igniter,
            %{spec: %{"openapi" => "3.0.0"}, bytes: @yaml, location: "priv/specs/a.yaml"}} =
             Load.load(igniter, "priv/specs/a.yaml")
  end

  test "a URL, with the format from its extension" do
    igniter = with_fetch(test_project(), %{"https://x.test/spec.json" => {:ok, @json}})

    assert {:ok, _igniter, %{spec: %{"openapi" => "3.1.0"}, location: "https://x.test/spec.json"}} =
             Load.load(igniter, "https://x.test/spec.json")
  end

  test "a URL without an extension is sniffed from its content" do
    igniter =
      with_fetch(test_project(), %{
        "https://x.test/openapi" => {:ok, @json},
        "https://x.test/openapi?format=yaml" => {:ok, @yaml}
      })

    assert {:ok, _, %{spec: %{"openapi" => "3.1.0"}}} =
             Load.load(igniter, "https://x.test/openapi")

    assert {:ok, _, %{spec: %{"openapi" => "3.0.0"}}} =
             Load.load(igniter, "https://x.test/openapi?format=yaml")
  end

  test "a fetch failure names the URL" do
    igniter = with_fetch(test_project(), %{})

    assert Load.load(igniter, "https://x.test/gone.yaml") ==
             {:error, {:fetch, "https://x.test/gone.yaml", {:status, 404}}}
  end

  test "a local registry shortcut resolves to its URL or file" do
    registry = %{
      "acme" => %{
        "1" => "https://acme.test/v1.yaml",
        "2" => "priv/specs/acme-2.json",
        "latest" => {:alias, "2"}
      }
    }

    igniter =
      test_project(files: %{"priv/specs/acme-2.json" => @json})
      |> with_fetch(%{"https://acme.test/v1.yaml" => {:ok, @yaml}})

    assert {:ok, _, %{spec: %{"openapi" => "3.0.0"}, location: "https://acme.test/v1.yaml"}} =
             Load.load(igniter, "acme@1", registry)

    assert {:ok, _, %{spec: %{"openapi" => "3.1.0"}, location: "priv/specs/acme-2.json"}} =
             Load.load(igniter, "acme", registry)
  end

  test "a built-in shortcut fetches the registry URL" do
    {:ok, %{location: url}} = Hearth.Registry.lookup("stripe@2026-04-22.dahlia")
    igniter = with_fetch(test_project(), %{url => {:ok, @yaml}})

    assert {:ok, _, %{location: ^url}} = Load.load(igniter, "stripe@2026-04-22.dahlia")
  end

  test "an unknown shortcut is a registry error" do
    assert {:error, {:registry, {:unknown_name, "nope"}}} = Load.load(test_project(), "nope")
  end

  test "file errors" do
    igniter = test_project(files: %{"priv/specs/bad.json" => "{"})

    assert Load.load(igniter, "priv/specs/missing.yaml") == {:error, :missing}
    assert {:error, {:decode, _}} = Load.load(igniter, "priv/specs/bad.json")
  end
end
