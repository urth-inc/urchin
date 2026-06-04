defmodule Urchin.Test.RejectValidator do
  @moduledoc false
  # Rejects every token; used where only the discovery/metadata path matters.

  @behaviour Urchin.Auth.TokenValidator

  @impl true
  def validate(_token, _auth), do: {:error, :invalid_token}
end

defmodule Urchin.Test.ScopeValidator do
  @moduledoc false
  # "good" carries the required scopes, "low" is authenticated but under-scoped.

  @behaviour Urchin.Auth.TokenValidator

  alias Urchin.Auth.Claims

  @aud ["https://mcp.example.com/mcp"]

  @impl true
  def validate("good", _auth),
    do: {:ok, %Claims{subject: "alice", scopes: ["files:read", "files:write"], audience: @aud}}

  def validate("low", _auth),
    do: {:ok, %Claims{subject: "bob", scopes: ["other"], audience: @aud}}

  def validate(_token, _auth), do: {:error, :invalid_token}
end

defmodule Urchin.Test.AliceValidator do
  @moduledoc false
  # Accepts a single known token and surfaces a subject + scopes for ctx.auth checks.

  @behaviour Urchin.Auth.TokenValidator

  alias Urchin.Auth.Claims

  @impl true
  def validate("alice-token", _auth) do
    {:ok,
     %Claims{subject: "alice", scopes: ["mcp:tools"], audience: ["https://mcp.example.com/mcp"]}}
  end

  def validate(_token, _auth), do: {:error, :invalid_token}
end
