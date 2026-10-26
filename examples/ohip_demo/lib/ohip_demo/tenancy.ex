defmodule OhipDemo.Tenancy do
  @moduledoc """
  The per-hotel OHIP values the generated client asks for when each
  request runs (`auth: [credential:]` and `base_url:` in `.hearth.exs`).

  Every call passes the hotel it acts for as `hotel:`; nothing here
  comes from config. A real app would look the token up in its own
  store, or fetch and cache one from OHIP's OAuth endpoint.
  """

  @type hotel :: %{id: String.t(), gateway: String.t(), token: String.t()}

  @doc "The bearer token for the call's `hotel:`."
  @spec token(keyword()) :: String.t() | nil
  def token(opts), do: get_in(opts, [:hotel, :token])

  @doc "The OHIP gateway URL for the call's `hotel:`."
  @spec gateway(keyword()) :: String.t() | nil
  def gateway(opts), do: get_in(opts, [:hotel, :gateway])
end
