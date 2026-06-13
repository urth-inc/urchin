defmodule Urchin.Auth.Metadata do
  @moduledoc """
  A `Plug` that serves the RFC 9728 Protected Resource Metadata document.

  This is the discovery endpoint MCP clients fetch to learn which Authorization
  Server(s) protect this MCP server. It is served at the well-known URI derived from the
  configured `:resource` (both the path-aware form and the bare root form, per RFC 9728
  §3.1) and is publicly readable with permissive CORS so browser-based clients can fetch
  it cross-origin.

  Mount it at the application root, ahead of your routes:

      plug Urchin.Auth.Metadata, auth: auth

  Requests that do not target a metadata path pass through untouched. The standalone
  `Urchin.Endpoint` runner wires this in automatically when `:auth` is configured.

  ## Options

    * `:auth` (required) - an `Urchin.Auth` struct or a keyword list of `Urchin.Auth.new!/1`
      options.
  """

  @behaviour Plug

  import Plug.Conn

  alias Urchin.Auth

  @impl true
  def init(opts) do
    auth =
      opts
      |> Keyword.get(:auth)
      |> Auth.coerce!() ||
        raise ArgumentError, "#{inspect(__MODULE__)} requires an :auth option"

    %{auth: auth}
  end

  @impl true
  def call(conn, %{auth: auth}) do
    if metadata_request?(conn, auth) do
      conn |> serve(auth) |> halt()
    else
      conn
    end
  end

  @doc "Returns true when the request targets the Protected Resource Metadata endpoint."
  @spec metadata_request?(Plug.Conn.t(), Auth.t()) :: boolean()
  def metadata_request?(conn, %Auth{} = auth) do
    conn.request_path in Auth.well_known_paths(auth, conn)
  end

  @doc """
  Sends the metadata document (or the appropriate CORS/405 response) for the request.

  Used by `call/2` and reused by `Urchin.Endpoint`. Does not halt; the caller decides.
  """
  @spec serve(Plug.Conn.t(), Auth.t()) :: Plug.Conn.t()
  def serve(%{method: method} = conn, %Auth{} = auth) when method in ["GET", "HEAD"] do
    conn
    |> put_cors()
    |> put_cache_control()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Auth.metadata_document(auth, conn)))
  end

  def serve(%{method: "OPTIONS"} = conn, _auth) do
    conn
    |> put_cors()
    |> put_cache_control()
    |> send_resp(204, "")
  end

  def serve(conn, _auth) do
    conn
    |> put_cors()
    |> put_cache_control()
    |> put_resp_header("allow", "GET, OPTIONS")
    |> put_resp_content_type("application/json")
    |> send_resp(
      405,
      Jason.encode!(%{
        error: "method_not_allowed",
        error_description: "The metadata endpoint only allows GET and OPTIONS"
      })
    )
  end

  # The metadata document must be fetchable by web-based MCP clients on any origin.
  defp put_cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Authorization, Content-Type")
  end

  defp put_cache_control(conn) do
    put_resp_header(conn, "cache-control", "no-store")
  end
end
