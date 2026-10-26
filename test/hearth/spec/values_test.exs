defmodule Hearth.Spec.ValuesTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Values

  describe "parse/1" do
    test "without any value keys: today's defaults" do
      assert Values.parse(module: X) ==
               {:ok, %{credential: {:config, :api_key}, headers: [], base_url: nil}}
    end

    test "the three forms, for every value" do
      entry = [
        auth: [
          scheme: "bearerAuth",
          credential: [resolve: {MyApp.Tenancy, :token}, options: [:tenant]]
        ],
        headers: [
          "X-App-Key": :app_key,
          "x-tenant-id": [option: :tenant_id],
          "x-region": [resolve: {MyApp.Tenancy, :region}]
        ],
        base_url: :base_url
      ]

      assert Values.parse(entry) ==
               {:ok,
                %{
                  credential: {:resolve, {MyApp.Tenancy, :token}, [:tenant]},
                  headers: [
                    {"x-app-key", {:config, :app_key}},
                    {"x-tenant-id", {:option, :tenant_id}},
                    {"x-region", {:resolve, {MyApp.Tenancy, :region}, []}}
                  ],
                  base_url: {:config, :base_url}
                }}
    end

    test "a credential or base URL given per call only" do
      assert {:ok, %{credential: {:option, :token}, base_url: {:option, :base_url}}} =
               Values.parse(auth: [credential: [option: :token]], base_url: [option: :base_url])
    end

    test "a resolver may share options with other values" do
      assert {:ok, _} =
               Values.parse(
                 auth: [credential: [resolve: {M, :token}, options: [:tenant_id]]],
                 headers: ["x-tenant-id": [option: :tenant_id]],
                 base_url: [resolve: {M, :gateway}, options: [:tenant_id]]
               )
    end

    test "rejects malformed forms, naming the value" do
      for {entry, named} <- [
            {[auth: [credential: "token"]], "`credential:`"},
            {[auth: [credential: [optoin: :token]]], "`credential:`"},
            {[auth: [credential: [resolve: Tenancy]]], "`credential:`"},
            {[auth: [credential: [resolve: {"M", :f}]]], "`credential:`"},
            {[auth: [credential: [option: :token, resolve: {M, :f}]]], "`credential:`"},
            {[auth: [credential: nil]], "`credential:`"},
            {[base_url: "https://x.test"], "`base_url:`"},
            {[headers: ["x-a": "a"]], ~s|`headers:` "x-a"|},
            {[headers: ["x-a": [option: "a"]]], ~s|`headers:` "x-a"|},
            {[headers: ["x-a": :"Not Valid"]], ~s|`headers:` "x-a"|},
            {[headers: ["bad header!": :key]], "`headers:`"},
            {[headers: :nope], "`headers:`"}
          ] do
        assert {:error, message} = Values.parse(entry), inspect(entry)
        assert message =~ named, inspect({entry, message})
      end
    end

    test "rejects two values with the same key" do
      for entry <- [
            [headers: ["x-a": :same, "x-b": [option: :same]]],
            [auth: [credential: :token], headers: ["x-a": :token]],
            [auth: [credential: [resolve: {M, :f}]], headers: ["x-a": :api_key]],
            [headers: ["x-a": :api_key]]
          ] do
        assert {:error, message} = Values.parse(entry), inspect(entry)
        assert message =~ "the same key"
      end
    end

    test "rejects keys that are already request options" do
      for entry <- [
            [headers: ["x-a": :params]],
            [headers: ["x-a": [option: :headers]]],
            [headers: ["x-a": [resolve: {M, :f}, options: [:json]]]],
            [auth: [credential: :retry]]
          ] do
        assert {:error, message} = Values.parse(entry), inspect(entry)
        assert message =~ "request option"
      end
    end

    test "the base URL's key is Req's own :base_url" do
      assert {:error, message} = Values.parse(base_url: :gateway)
      assert message =~ ":base_url"

      assert {:error, _} = Values.parse(base_url: [option: :gateway])
    end
  end

  describe "readers" do
    test "options/1: what new/1 registers, in order, without Req's own" do
      {:ok, values} =
        Values.parse(
          auth: [credential: [resolve: {M, :token}, options: [:tenant]]],
          headers: [
            "x-a": :app_key,
            "x-t": [option: :tenant_id],
            "x-r": [resolve: {M, :r}, options: [:tenant]]
          ],
          base_url: [resolve: {M, :gateway}, options: [:region]]
        )

      assert Values.options(values, true) == [:api_key, :tenant, :app_key, :tenant_id, :region]
      assert Values.options(values, false) == [:app_key, :tenant_id, :tenant, :region]
    end

    test "config_keys/2: the keys runtime.exs gets, only bare ones" do
      {:ok, values} =
        Values.parse(
          headers: ["x-a": :app_key, "x-t": [option: :tenant_id]],
          base_url: :base_url
        )

      assert Values.config_keys(values, true) == [:api_key, :app_key, :base_url]
      assert Values.config_keys(values, false) == [:app_key, :base_url]

      {:ok, values} = Values.parse(auth: [credential: [option: :token]])
      assert Values.config_keys(values, true) == []
    end
  end
end
