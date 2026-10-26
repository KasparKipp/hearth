defmodule OhipDemo.Tenancy.Tokens do
  @moduledoc """
  One OHIP token per chain environment, kept in an ETS table until a
  minute before it expires. The process only owns the table; reads and
  writes go straight to ETS.

  Two callers that miss at the same moment both request a token, and
  the later one is kept. A real app might serialize that per chain.
  """

  use GenServer

  @table __MODULE__
  @margin 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The chain's cached token, else the one `request` returns as `{token, expires_in}`."
  @spec fetch(OhipDemo.Tenancy.chain(), (-> {String.t(), non_neg_integer()})) :: String.t()
  def fetch(chain, request) do
    key = {chain.gateway, chain.client_id, chain.enterprise_id}
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at > now ->
        token

      _ ->
        {token, expires_in} = request.()
        :ets.insert(@table, {key, token, now + expires_in - @margin})
        token
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
