defmodule Hearth.RegistryTest do
  use ExUnit.Case, async: true

  alias Hearth.Registry

  describe "lookup/1" do
    test "bare name resolves to @latest" do
      assert {:ok,
              %{
                name: "stripe",
                version: "latest",
                location: "https://" <> _,
                integration: "Stripe"
              }} = Registry.lookup("stripe")
    end

    test "name@latest is equivalent to bare name" do
      {:ok, bare} = Registry.lookup("stripe")
      {:ok, pinned} = Registry.lookup("stripe@latest")
      assert bare == pinned
    end

    test "date.codename is a canonical entry — direct, no alias indirection" do
      {:ok, %{version: "2026-04-22.dahlia", resolved_version: "2026-04-22.dahlia"}} =
        Registry.lookup("stripe@2026-04-22.dahlia")
    end

    test "@latest is also a canonical entry, with its own floating URL" do
      {:ok, latest} = Registry.lookup("stripe@latest")
      {:ok, dated} = Registry.lookup("stripe@2026-04-22.dahlia")

      assert latest.version == "latest"
      assert latest.resolved_version == "latest"

      # Same content today, but the URLs are distinct so the cache treats
      # them as separate sources. `latest` floats; the dated form is
      # frozen.
      refute latest.location == dated.location
      assert latest.location =~ "refs/heads/master"
      assert dated.location =~ "v2266"
    end

    test "codename alias resolves to the canonical date.codename URL" do
      {:ok, canonical} = Registry.lookup("stripe@2026-04-22.dahlia")
      {:ok, dahlia} = Registry.lookup("stripe@dahlia")

      assert dahlia.location == canonical.location
      assert dahlia.version == "dahlia"
      assert dahlia.resolved_version == "2026-04-22.dahlia"
    end

    test "date alias resolves to the canonical date.codename URL" do
      {:ok, canonical} = Registry.lookup("stripe@2026-04-22.dahlia")
      {:ok, dated} = Registry.lookup("stripe@2026-04-22")

      assert dated.location == canonical.location
      assert dated.version == "2026-04-22"
      assert dated.resolved_version == "2026-04-22.dahlia"
    end

    test "@basil resolves to the most recent dated basil release" do
      {:ok, canonical} = Registry.lookup("stripe@2025-08-27.basil")
      {:ok, family} = Registry.lookup("stripe@basil")

      assert family.location == canonical.location
      assert family.location =~ "v2017"
      assert family.resolved_version == "2025-08-27.basil"
    end

    test "@clover resolves to the most recent dated clover release" do
      {:ok, canonical} = Registry.lookup("stripe@2026-02-25.clover")
      {:ok, family} = Registry.lookup("stripe@clover")

      assert family.location == canonical.location
      assert family.location =~ "v2203"
      assert family.resolved_version == "2026-02-25.clover"
    end

    test "historic dated entries resolve to their pinned tag URLs" do
      {:ok, oldest_basil} = Registry.lookup("stripe@2025-03-31.basil")
      assert oldest_basil.location =~ "v1712"

      {:ok, mid_clover} = Registry.lookup("stripe@2025-12-15.clover")
      assert mid_clover.location =~ "v2139"

      {:ok, older_dahlia} = Registry.lookup("stripe@2026-03-25.dahlia")
      assert older_dahlia.location =~ "v2248"
    end

    test "date-alone aliases work across codename families" do
      # Basil family
      {:ok, dated} = Registry.lookup("stripe@2025-04-30")
      assert dated.resolved_version == "2025-04-30.basil"
      assert dated.location =~ "v1769"

      # Clover family
      {:ok, dated} = Registry.lookup("stripe@2025-11-17")
      assert dated.resolved_version == "2025-11-17.clover"
      assert dated.location =~ "v2132"
    end

    test "unknown name returns :unknown_name error" do
      assert Registry.lookup("nonexistent") == {:error, {:unknown_name, "nonexistent"}}
    end

    test "known name with unknown version returns :unknown_version error with canonical list only" do
      assert {:error, {:unknown_version, "stripe", "2099-01-01", available}} =
               Registry.lookup("stripe@2099-01-01")

      assert "latest" in available
      assert "2026-04-22.dahlia" in available
      assert hd(available) == "latest"

      # Aliases are invisible to listings — only canonical (URL-backed)
      # entries appear.
      refute "dahlia" in available
      refute "2026-04-22" in available
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

    test "lists only canonical (URL-backed) versions — aliases are filtered out" do
      versions = Registry.versions("stripe")

      assert "latest" in versions
      assert "2026-04-22.dahlia" in versions

      # Aliases still resolve at lookup time but never appear in listings.
      refute "dahlia" in versions
      refute "2026-04-22" in versions
    end

    test "returns nil for an unknown shortcut" do
      assert Registry.versions("nonexistent") == nil
    end
  end

  describe "a local registry" do
    @local %{
      "ohip_blk" => %{
        "26.2" => "https://example.com/26.2/blk.json",
        "26.3" => "priv/specs/blk-26.3.json",
        "latest" => {:alias, "26.3"}
      },
      "stripe" => %{"mirror" => "https://mirror.example.com/stripe.yaml"}
    }

    test "resolves its entries, aliases and file locations included" do
      assert {:ok,
              %{
                location: "https://example.com/26.2/blk.json",
                local?: true,
                integration: "OhipBlk"
              }} =
               Registry.lookup("ohip_blk@26.2", @local)

      assert {:ok, %{location: "priv/specs/blk-26.3.json", resolved_version: "26.3"}} =
               Registry.lookup("ohip_blk", @local)
    end

    test "shadows a built-in name" do
      assert {:ok, %{location: "https://mirror.example.com/stripe.yaml", local?: true}} =
               Registry.lookup("stripe@mirror", @local)

      assert {:error, {:unknown_version, "stripe", "latest", ["mirror"]}} =
               Registry.lookup("stripe", @local)
    end

    test "built-in entries are not local" do
      assert {:ok, %{local?: false}} = Registry.lookup("stripe")
    end

    test "list/1 and versions/2 merge it in" do
      assert "ohip_blk" in Registry.list(@local)
      assert Registry.versions("ohip_blk", @local) == ["26.3", "26.2"]
    end
  end
end
