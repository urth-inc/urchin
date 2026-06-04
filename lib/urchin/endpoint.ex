defmodule Urchin.Endpoint do
  @moduledoc """
  A standalone HTTP endpoint that serves an MCP server with Bandit.

  This is both a `Plug` (routing the configured path to
  `Urchin.Transport.StreamableHTTP`) and a supervisable process.

      children = [{Urchin.Endpoint, server: MyServer, port: 4000, path: "/mcp"}]

  or, for a quick start, `Urchin.start_link/2`.

  ## Options

    * `:server` (required) - the `Urchin.Server` module
    * `:port` - listen port (default `4000`)
    * `:ip` - listen address (default `{127, 0, 0, 1}`; bind localhost only)
    * `:path` - the MCP endpoint path (default `"/mcp"`)
    * `:scheme` - `:http` or `:https` (default `:http`)

  Remaining options are forwarded to `Urchin.Transport.StreamableHTTP`. Requires the
  optional `:bandit` dependency.
  """

  @behaviour Plug

  import Plug.Conn

  @default_port 4000
  @default_path "/mcp"

  @doc "Starts the endpoint linked to the calling process."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    ensure_bandit!()
    {bandit_opts, plug_opts} = split_opts(opts)
    Bandit.start_link([plug: {__MODULE__, plug_opts}] ++ bandit_opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)
    transport_opts = Keyword.drop(opts, [:port, :ip, :scheme, :path, :name])

    %{
      path_info: path_to_segments(path),
      transport: Urchin.Transport.StreamableHTTP.init(transport_opts)
    }
  end

  @impl true
  def call(conn, %{path_info: path_info, transport: transport}) do
    if conn.path_info == path_info do
      Urchin.Transport.StreamableHTTP.call(conn, transport)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp split_opts(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    scheme = Keyword.get(opts, :scheme, :http)

    bandit_opts = [scheme: scheme, port: port, ip: ip]
    {bandit_opts, opts}
  end

  defp path_to_segments(path) do
    path
    |> String.split("/", trim: true)
  end

  defp ensure_bandit! do
    Code.ensure_loaded?(Bandit) ||
      raise """
      Urchin.Endpoint requires the optional :bandit dependency. Add it to your deps:

          {:bandit, "~> 1.6"}
      """
  end
end
