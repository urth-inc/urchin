defmodule Urchin.Auth.Plug do
  @moduledoc """
  A `Plug` that enforces a valid OAuth 2.1 bearer token on every request.

  Mount it ahead of the MCP transport in a Plug/Phoenix pipeline:

      plug Urchin.Auth.Metadata, auth: auth
      plug Urchin.Auth.Plug, auth: auth
      forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: MyServer]

  Most servers instead pass `:auth` directly to `Urchin.Transport.StreamableHTTP` (or
  `Urchin.start_link/2`), which runs the very same check internally. This standalone plug
  is for custom pipelines that want authorization as an explicit pipeline stage.

  On success the validated `Urchin.Auth.Claims` are stored under `conn.private[:urchin_auth]`;
  the transport reads that key and surfaces it to handlers as `ctx.auth`, regardless of
  whether this plug or the transport performed the check. On failure the plug sends the
  appropriate `401`/`403`/`400`/`500` OAuth error with a `WWW-Authenticate` challenge and
  halts the pipeline.

  ## Options

    * `:auth` (required) - an `Urchin.Auth` struct or a keyword list of `Urchin.Auth.new!/1`
      options.
  """

  @behaviour Plug

  import Plug.Conn

  alias Urchin.Auth

  @private_key :urchin_auth

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
    case authenticate(conn, auth) do
      {:ok, conn} -> conn
      {:sent, conn} -> halt(conn)
    end
  end

  @doc """
  The shared authentication seam used by this plug and `Urchin.Transport.StreamableHTTP`.

  Returns `{:ok, conn}` with the validated claims stored in `conn.private[:urchin_auth]`,
  or `{:sent, conn}` after sending the OAuth error challenge. When `auth` is `nil`
  (authorization disabled) the connection passes through untouched.
  """
  @spec authenticate(Plug.Conn.t(), Auth.t() | nil) ::
          {:ok, Plug.Conn.t()} | {:sent, Plug.Conn.t()}
  def authenticate(conn, nil), do: {:ok, conn}

  def authenticate(conn, %Auth{} = auth) do
    token = bearer_token(conn)

    case Auth.authorize(auth, token, conn) do
      {:ok, claims} ->
        {:ok, put_private(conn, @private_key, claims)}

      {:error, kind, message} ->
        {status, www_authenticate, body} = Auth.challenge(auth, kind, message, conn)

        conn =
          conn
          |> maybe_put_challenge(www_authenticate)
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))

        {:sent, conn}
    end
  end

  @doc "Returns the validated claims stored on the connection, or `nil`."
  @spec fetch_claims(Plug.Conn.t()) :: Auth.Claims.t() | nil
  def fetch_claims(conn), do: Map.get(conn.private, @private_key)

  # MCP requires the access token in the Authorization header only (never the query
  # string); read exactly that and ignore any other location.
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] -> parse_bearer(value)
      [] -> nil
    end
  end

  defp parse_bearer(value) do
    case String.split(value, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: String.trim(token), else: nil
      _ -> nil
    end
  end

  defp maybe_put_challenge(conn, nil), do: conn
  defp maybe_put_challenge(conn, header), do: put_resp_header(conn, "www-authenticate", header)
end
