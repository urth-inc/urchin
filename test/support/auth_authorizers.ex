defmodule Urchin.Test.RejectAuthorizer do
  @moduledoc false
  # Rejects every token; used where only the discovery/metadata path matters.

  @behaviour Urchin.Auth.Authorizer

  @impl true
  def authorize(nil, _auth, _conn), do: {:error, :missing, "Authorization required"}
  def authorize(_token, _auth, _conn), do: {:error, :invalid_token}
end

defmodule Urchin.Test.ScopeAuthorizer do
  @moduledoc false
  # "good" carries the required scopes, "low" is authenticated but under-scoped.

  @behaviour Urchin.Auth.Authorizer

  alias Urchin.Auth.Claims

  @aud ["https://mcp.example.com/mcp"]

  @impl true
  def authorize(nil, _auth, _conn), do: {:error, :missing, "Authorization required"}

  def authorize("good", auth, conn) do
    authorize_claims(
      %Claims{subject: "alice", scopes: ["files:read", "files:write"], audience: @aud},
      auth,
      conn
    )
  end

  def authorize("low", auth, conn) do
    authorize_claims(%Claims{subject: "bob", scopes: ["other"], audience: @aud}, auth, conn)
  end

  def authorize(_token, _auth, _conn), do: {:error, :invalid_token}

  defp authorize_claims(%Claims{} = claims, auth, conn) do
    cond do
      auth.resource not in claims.audience ->
        {:error, :invalid_token, "Token audience is invalid"}

      not Claims.has_scopes?(claims, Urchin.Auth.required_scopes(auth, conn)) ->
        {:error, :insufficient_scope, "Insufficient scope"}

      true ->
        {:ok, claims}
    end
  end
end

defmodule Urchin.Test.AliceAuthorizer do
  @moduledoc false
  # Accepts a single known token and surfaces a subject + scopes for ctx.auth checks.

  @behaviour Urchin.Auth.Authorizer

  alias Urchin.Auth.Claims

  @impl true
  def authorize(nil, _auth, _conn), do: {:error, :missing, "Authorization required"}

  def authorize("alice-token", _auth, _conn) do
    {:ok,
     %Claims{subject: "alice", scopes: ["mcp:tools"], audience: ["https://mcp.example.com/mcp"]}}
  end

  def authorize(_token, _auth, _conn), do: {:error, :invalid_token}
end
