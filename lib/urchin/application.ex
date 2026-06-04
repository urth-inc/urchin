defmodule Urchin.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Urchin.Session.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Urchin.Session.Supervisor}
    ]

    opts = [strategy: :one_for_one, name: Urchin.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
