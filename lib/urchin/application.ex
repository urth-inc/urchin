defmodule Urchin.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Urchin.Session.Registry},
      Urchin.Session.Limiter,
      {DynamicSupervisor, strategy: :one_for_one, name: Urchin.Session.Supervisor}
    ]

    # :rest_for_one so that if the session Limiter crashes, the session supervisor (and its
    # sessions) restart with it, keeping the cap count consistent rather than under-counting.
    opts = [strategy: :rest_for_one, name: Urchin.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
