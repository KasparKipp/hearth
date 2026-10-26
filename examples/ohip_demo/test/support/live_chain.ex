defmodule OhipDemo.LiveChain do
  @moduledoc """
  The hotel chain the live-API tests (`mix test --include external`) act
  for, read from env vars: `OHIP_GATEWAY_URL`, `OHIP_APP_KEY`,
  `OHIP_CLIENT_ID`, `OHIP_CLIENT_SECRET`, `OHIP_ENTERPRISE_ID`,
  `OHIP_SCOPE`, plus `OHIP_HOTEL_ID` for the hotel.
  """

  @spec chain!() :: OhipDemo.Tenancy.chain()
  def chain! do
    %{
      gateway: System.fetch_env!("OHIP_GATEWAY_URL"),
      app_key: System.fetch_env!("OHIP_APP_KEY"),
      client_id: System.fetch_env!("OHIP_CLIENT_ID"),
      client_secret: System.fetch_env!("OHIP_CLIENT_SECRET"),
      enterprise_id: System.fetch_env!("OHIP_ENTERPRISE_ID"),
      scope: System.fetch_env!("OHIP_SCOPE")
    }
  end

  @spec hotel_id!() :: String.t()
  def hotel_id!, do: System.fetch_env!("OHIP_HOTEL_ID")
end
