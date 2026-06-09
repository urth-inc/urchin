defmodule Urchin.Auth.Authorizer do
  @moduledoc """
  Behaviour for making the final OAuth authorization decision for a request.

  An authorizer is supplied to `Urchin.Auth.new!/1` as `:authorizer` and may be:

    * a module implementing this behaviour (`c:authorize/3`), or
    * a 3-arity function `fn token, auth, conn -> result end`.

  `authorize/3` receives the bearer token (or `nil` when no bearer token was present), the
  `Urchin.Auth` configuration and the current request context (`Plug.Conn` in the HTTP
  transport). It owns the full decision: token validity, issuer, expiry, audience/resource
  binding, scopes and tenant-specific policy.

  The SDK uses the result only to either pass claims to handlers as `ctx.auth`, or to build
  the standard OAuth `WWW-Authenticate` challenge.

  ## Example

      defmodule MyAuthorizer do
        @behaviour Urchin.Auth.Authorizer

        @impl true
        def authorize(nil, _auth, _conn), do: {:error, :missing, "Authorization required"}

        def authorize(token, auth, conn) do
          with {:ok, payload} <- verify_signature_and_decode(token, conn),
               claims = Urchin.Auth.Claims.from_map(payload),
               :ok <- ensure_audience(claims, auth.resource),
               :ok <- ensure_scopes(claims, Urchin.Auth.required_scopes(auth, conn)) do
            {:ok, claims}
          else
            :bad_audience -> {:error, :invalid_token, "Token audience is invalid"}
            :insufficient_scope -> {:error, :insufficient_scope, "Insufficient scope"}
            :error -> {:error, :invalid_token, "Invalid access token"}
          end
        end
      end
  """

  alias Urchin.Auth
  alias Urchin.Auth.Claims

  @type reason ::
          :missing | :invalid_token | :expired | :invalid_audience | :insufficient_scope | term()
  @type kind :: :missing | :invalid_token | :insufficient_scope | :invalid_request | :server_error
  @type result :: {:ok, Claims.t()} | {:error, reason()} | {:error, kind(), String.t()}

  @callback authorize(token :: String.t() | nil, auth :: Auth.t(), conn :: term()) :: result()
end
