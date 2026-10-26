defmodule OhipDemo.Integrations.OhipOauthExternalTest do
  @moduledoc false

  # Generated once by Hearth — a scaffold for real HTTP calls
  # against the live API. Hearth never overwrites this file; edit
  # it freely. Tagged `:external` and skipped by `mix test` — run
  # it with `mix test --include external`.

  use ExUnit.Case, async: true

  @moduletag :external

  alias OhipDemo.Integrations.OhipOauth.OhipOauthApi

  # The chain's client credentials, app key and enterprise ID come from
  # `OhipDemo.Tenancy` (`OhipDemo.LiveChain` reads them from env vars).
  test "get_token returns a bearer token for the chain" do
    chain = OhipDemo.LiveChain.chain!()
    form = [grant_type: "client_credentials", scope: chain.scope]

    assert {:ok, %Req.Response{status: 200, body: %{"access_token" => _}}} =
             OhipOauthApi.Req.get_token(form: form, chain: chain)
  end
end
