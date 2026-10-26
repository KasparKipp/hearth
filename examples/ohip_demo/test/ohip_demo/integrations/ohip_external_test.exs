defmodule OhipDemo.Integrations.OhipExternalTest do
  @moduledoc false

  # Generated once by Hearth — a scaffold for real HTTP calls
  # against the live API. Hearth never overwrites this file; edit
  # it freely. Tagged `:external` and skipped by `mix test` — run
  # it with `mix test --include external`.

  use ExUnit.Case, async: false

  @moduletag :external

  alias OhipDemo.Integrations.Ohip.OhipApi
  @client OhipDemo.Integrations.Ohip

  setup do
    # Merge into the existing config — `config/test.exs` sets a
    # `:base_url` on @client; a bare `put_env` would wipe it and the
    # external test would hit production.
    previous = Application.get_env(:ohip_demo, @client, [])

    config =
      Keyword.merge(previous,
        app_key: System.get_env("OHIP_APP_KEY") || "DEV_NO_OHIP_APP_KEY"
      )

    Application.put_env(:ohip_demo, @client, config)
    on_exit(fn -> Application.put_env(:ohip_demo, @client, previous) end)
    :ok
  end

  # Values Layer 1 takes per call, never from config.
  defp opts do
    [hotel_id: System.get_env("OHIP_HOTEL_ID") || "DEV_NO_OHIP_HOTEL_ID"]
  end

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
