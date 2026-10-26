defmodule OhipDemo.Integrations.OhipExternalTest do
  @moduledoc false

  # Generated once by Hearth — a scaffold for real HTTP calls
  # against the live API. Hearth never overwrites this file; edit
  # it freely. Tagged `:external` and skipped by `mix test` — run
  # it with `mix test --include external`.

  use ExUnit.Case, async: false

  @moduletag :external

  alias OhipDemo.Integrations.Ohip.OhipApi
  alias OhipDemo.Integrations.OhipOauth.OhipOauthApi

  # `OhipDemo.Tenancy` gets the token through `OhipOauthApi`, which
  # `config/test.exs` points at its Mox mock; here it has to be the real
  # one.
  setup do
    previous = Application.get_env(:ohip_demo, OhipOauthApi, [])
    Application.put_env(:ohip_demo, OhipOauthApi, Keyword.put(previous, :impl, OhipOauthApi.Req))
    on_exit(fn -> Application.put_env(:ohip_demo, OhipOauthApi, previous) end)
    :ok
  end

  # The chain and the hotel every call acts for (`OhipDemo.LiveChain`).
  defp opts, do: [chain: OhipDemo.LiveChain.chain!(), hotel_id: OhipDemo.LiveChain.hotel_id!()]

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_blocks reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_blocks(opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_block reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_block("TODO", "TODO", opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_block_range_info reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_block_range_info("TODO", "TODO", opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_block_room_rate_grid reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_block_room_rate_grid("TODO", "TODO", opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_event_calendar reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_event_calendar("TODO", opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_events_one_hotel reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_events_one_hotel("TODO", opts())
  end

  # TODO: replace the placeholder args/opts and assert on your use-case.
  test "get_event reaches the live API" do
    assert {:ok, %Req.Response{}} = OhipApi.Req.get_event("TODO", "TODO", opts())
  end
end
