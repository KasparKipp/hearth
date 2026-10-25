defmodule Hearth.Spec.FetcherTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Fetcher
  alias Hearth.TestHTTP

  @spec_body "openapi: 3.0.0\n"

  setup do
    port =
      TestHTTP.start(%{
        "/spec.yaml" => {200, [{"content-type", "application/yaml"}], @spec_body},
        "/moved.yaml" => {302, [{"location", "/spec.yaml"}], ""},
        "/broken.yaml" => {500, [], "boom"}
      })

    %{base: "http://127.0.0.1:#{port}"}
  end

  test "returns the body of a 200", %{base: base} do
    assert Fetcher.fetch(base <> "/spec.yaml") == {:ok, @spec_body}
  end

  test "follows a redirect", %{base: base} do
    assert Fetcher.fetch(base <> "/moved.yaml") == {:ok, @spec_body}
  end

  test "a non-2xx status is an error naming it", %{base: base} do
    assert Fetcher.fetch(base <> "/missing.yaml") == {:error, {:status, 404}}
    assert Fetcher.fetch(base <> "/broken.yaml") == {:error, {:status, 500}}
  end

  test "a connection failure is an error" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, _reason} = Fetcher.fetch("http://127.0.0.1:#{port}/spec.yaml")
  end

  describe "describe_error/1" do
    test "words the common failures" do
      assert Fetcher.describe_error({:status, 404}) =~ "HTTP 404"
      assert Fetcher.describe_error({:failed_connect, []}) =~ "could not connect"

      assert Fetcher.describe_error(
               {:failed_connect, [{:to_address, {~c"x", 1}}, {:inet, [:inet], :econnrefused}]}
             ) ==
               "could not connect (:econnrefused)"

      tls = {:tls_alert, {:certificate_expired, ~c"Certificate Expired"}}

      assert Fetcher.describe_error({:failed_connect, [{:inet, [:inet], tls}]}) ==
               "TLS failed: Certificate Expired"

      assert Fetcher.describe_error(:timeout) =~ "timed out"
    end
  end
end
