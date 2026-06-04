defmodule Urchin do
  @moduledoc """
  A Model Context Protocol (MCP) server library implementing the `2025-11-25`
  specification over the Streamable HTTP transport.

  See `Urchin.Server` for authoring a server (behaviour or DSL) and
  `Urchin.Transport.StreamableHTTP` for mounting it as a `Plug`. The convenience
  runner below boots a server with a standalone Bandit endpoint.
  """

  @doc """
  Starts a server module behind a standalone Bandit HTTP endpoint.

  Requires the optional `:bandit` dependency. Options are forwarded to
  `Urchin.Endpoint.start_link/1`; common ones are `:port`, `:path`, `:ip` and
  transport options such as `:allowed_origins`.

  ## Example

      {:ok, _pid} = Urchin.start_link(MyServer, port: 4000, path: "/mcp")
  """
  @spec start_link(module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(server, opts \\ []) when is_atom(server) do
    Urchin.Endpoint.start_link(Keyword.put(opts, :server, server))
  end

  @doc "The latest protocol revision implemented by this library."
  @spec protocol_version() :: String.t()
  def protocol_version, do: Urchin.Protocol.latest_version()

  @doc """
  Sends a notification to every active session on its general (GET) stream.

  Useful for fan-out notifications such as `notifications/tools/list_changed` or
  `notifications/resources/list_changed`. Sessions without a connected GET stream
  buffer the notification for resumption.

  Returns the number of sessions notified.
  """
  @spec broadcast(String.t(), map() | nil) :: non_neg_integer()
  def broadcast(method, params \\ nil) when is_binary(method) do
    Urchin.Session.Registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.reduce(0, fn pid, count ->
      Urchin.Session.notify(pid, method, params)
      count + 1
    end)
  end
end
