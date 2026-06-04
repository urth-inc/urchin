defmodule Urchin.Protocol do
  @moduledoc """
  Protocol-level constants and version negotiation for the Model Context Protocol.

  This library implements the `2025-11-25` revision. Older revisions are listed as
  acceptable negotiation targets so that the server can interoperate with clients
  that have not yet upgraded.
  """

  @jsonrpc_version "2.0"
  @latest_version "2025-11-25"

  # Revisions this server is willing to speak, newest first. The first entry is the
  # version this library is built against.
  @supported_versions [
    "2025-11-25",
    "2025-06-18",
    "2025-03-26"
  ]

  # Fallback assumed when an HTTP request omits the MCP-Protocol-Version header and
  # the version cannot otherwise be determined (per the transport spec).
  @default_negotiated_version "2025-03-26"

  @doc "The JSON-RPC version string used by all messages."
  @spec jsonrpc_version() :: String.t()
  def jsonrpc_version, do: @jsonrpc_version

  @doc "The latest protocol revision implemented by this library."
  @spec latest_version() :: String.t()
  def latest_version, do: @latest_version

  @doc "All protocol revisions this server can negotiate, newest first."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc """
  The protocol version assumed for HTTP requests that omit the
  `MCP-Protocol-Version` header (transport backwards-compatibility rule).
  """
  @spec default_negotiated_version() :: String.t()
  def default_negotiated_version, do: @default_negotiated_version

  @doc "Returns true when `version` is a revision this server can speak."
  @spec supported?(String.t()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported_versions
  def supported?(_), do: false

  @doc """
  Negotiates a protocol version from the client's requested version.

  If the requested version is supported, it is echoed back. Otherwise the server's
  latest version is returned, leaving it to the client to decide whether it can
  proceed (per the lifecycle spec, the client disconnects if it cannot).
  """
  @spec negotiate(String.t()) :: String.t()
  def negotiate(requested) when is_binary(requested) do
    if supported?(requested), do: requested, else: @latest_version
  end
end
