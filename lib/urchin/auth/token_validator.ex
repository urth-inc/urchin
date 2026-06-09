defmodule Urchin.Auth.TokenValidator do
  @moduledoc """
  Behaviour for validating inbound OAuth 2.1 access tokens.

  A validator is the pluggable seam through which Urchin, acting as an OAuth 2.1
  Resource Server, performs the token checks required by the MCP authorization spec
  (OAuth 2.1 §5.2): signature/introspection, expiry and issuer. The configured
  `Urchin.Auth` additionally enforces audience binding (RFC 8707) and scopes around the
  validator, so a validator only needs to answer "is this token genuine?".

  A validator is supplied to `Urchin.Auth.new!/1` as `:token_validator` and may be:

    * a module implementing this behaviour (`c:validate/3`), or
    * a 3-arity function `fn token, auth, conn -> result end`.

  `validate/3` receives the access token, the `Urchin.Auth` configuration and the current
  request context (`Plug.Conn` in the HTTP transport). It must return one of:

    * `{:ok, Urchin.Auth.Claims.t()}` — the token is valid; the claims flow to handlers
      as `ctx.auth`.
    * `{:error, reason}` — the token is rejected with a generic 401. Recognized reasons
      (`:invalid_token`, `:expired`, `:invalid_audience`, `:insufficient_scope`, ...) select
      the status; any other reason (including a bare binary) becomes a generic
      `invalid_token` whose detail is never echoed to the client.
    * `{:error, kind, message}` — full control over the challenge, where `kind` is one of
      `:invalid_token` (401), `:insufficient_scope` (403), `:invalid_request` (400) or
      `:server_error` (500). The `message` is returned verbatim to the (unauthenticated)
      client, so it must not contain secrets, internal hostnames or stack traces.

  Audience: under the default `audience_validation: :auto`, Urchin enforces RFC 8707 binding
  for you — populate `Urchin.Auth.Claims.audience` (`from_map/1` does this from the `aud`
  claim) and a token whose audience omits this resource, or has none, is rejected. For opaque
  tokens whose audience you verify yourself, configure `audience_validation: :skip`.

  ## Example (HS256 JWT, illustrative)

      defmodule MyValidator do
        @behaviour Urchin.Auth.TokenValidator

        @impl true
        def validate(token, _auth, _conn) do
          case verify_signature_and_decode(token) do
            {:ok, payload} -> {:ok, Urchin.Auth.Claims.from_map(payload)}
            :error -> {:error, :invalid_token}
          end
        end
      end
  """

  alias Urchin.Auth
  alias Urchin.Auth.Claims

  @type reason :: :invalid_token | :expired | :invalid_audience | :insufficient_scope | term()
  @type kind :: :invalid_token | :insufficient_scope | :invalid_request | :server_error
  @type result :: {:ok, Claims.t()} | {:error, reason()} | {:error, kind(), String.t()}

  @callback validate(token :: String.t(), auth :: Auth.t(), conn :: term()) :: result()
end
