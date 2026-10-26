defmodule OhipDemo.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([OhipDemo.Tenancy.Tokens],
      strategy: :one_for_one,
      name: OhipDemo.Supervisor
    )
  end
end
