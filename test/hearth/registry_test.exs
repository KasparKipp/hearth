defmodule Hearth.RegistryTest do
  use ExUnit.Case, async: true

  alias Hearth.Registry

  describe "lookup/1" do
    test "bare name resolves to @latest" do
      assert {:ok,
              %{
                name: "stripe",
                version: "latest",
                url: "https://" <> _,
                integration: "Stripe"
              }} = Registry.lookup("stripe")
    end

    test "name@latest is equivalent to bare name" do
      {:ok, bare} = Registry.lookup("stripe")
      {:ok, pinned} = Registry.lookup("stripe@latest")
      assert bare == pinned
    end

    test "date.codename is the canonical entry — no alias indirection" do
      {:ok, %{version: "2026-04-22.dahlia", resolved_version: "2026-04-22.dahlia"}} =
        Registry.lookup("stripe@2026-04-22.dahlia")
    end

    test "@latest is an alias for the current date.codename" do
      {:ok, canonical} = Registry.lookup("stripe@2026-04-22.dahlia")
      {:ok, latest} = Registry.lookup("stripe@latest")

      assert latest.url == canonical.url
      assert latest.version == "latest"
      assert latest.resolved_version == "2026-04-22.dahlia"
    end

    test "codename alias resolves to the canonical date.codename URL" do
      {:ok, canonical} = Registry.lookup("stripe@2026-04-22.dahlia")
      {:ok, dahlia} = Registry.lookup("stripe@dahlia")

      assert dahlia.url == canonical.url
      assert dahlia.version == "dahlia"
      assert dahlia.resolved_version == "2026-04-22.dahlia"
    end

    test "date alias resolves to the canonical date.codename URL" do
      {:ok, canonical} = Registry.lookup("stripe@2026-04-22.dahlia")
      {:ok, dated} = Registry.lookup("stripe@2026-04-22")

      assert dated.url == canonical.url
      assert dated.version == "2026-04-22"
      assert dated.resolved_version == "2026-04-22.dahlia"
    end

    test "unknown name returns :unknown_name error" do
      assert Registry.lookup("nonexistent") == {:error, {:unknown_name, "nonexistent"}}
    end

    test "known name with unknown version returns :unknown_version error with available list" do
      assert {:error, {:unknown_version, "stripe", "2099-01-01", available}} =
               Registry.lookup("stripe@2099-01-01")

      assert "latest" in available
      assert "dahlia" in available
      assert hd(available) == "latest"
    end

    test "default integration name is derived via Macro.camelize" do
      {:ok, %{integration: integration}} = Registry.lookup("stripe")
      assert integration == "Stripe"
      assert integration == Macro.camelize("stripe")
    end

    test "Macro.camelize handles underscored shortcuts correctly" do
      # Document the convention without polluting the real registry.
      assert Macro.camelize("google_docs") == "GoogleDocs"
      assert Macro.camelize("aws_s3") == "AwsS3"
    end

    test "lookup is case-sensitive — callers should pre-normalize" do
      # Hearth.Spec.Source.resolve/1 downcases registry inputs before lookup.
      assert Registry.lookup("Stripe") == {:error, {:unknown_name, "Stripe"}}
    end
  end

  describe "list/0" do
    test "lists known shortcuts in sorted order" do
      shortcuts = Registry.list()
      assert "stripe" in shortcuts
      assert shortcuts == Enum.sort(shortcuts)
    end
  end

  describe "versions/1" do
    test "returns sorted version list for a known shortcut" do
      versions = Registry.versions("stripe")
      assert is_list(versions)
      assert "latest" in versions
      # `latest` is always sorted to the front.
      assert hd(versions) == "latest"
    end

    test "includes alias keys alongside canonical versions" do
      versions = Registry.versions("stripe")
      assert "dahlia" in versions
      assert "2026-04-22" in versions
      assert "2026-04-22.dahlia" in versions
    end

    test "returns nil for an unknown shortcut" do
      assert Registry.versions("nonexistent") == nil
    end
  end
end
