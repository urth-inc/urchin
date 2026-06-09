defmodule Urchin.Auth.Claims do
  @moduledoc """
  Normalized claims for a validated OAuth 2.1 access token.

  An `Urchin.Auth.Authorizer` returns one of these from `authorize/3`. The transport
  surfaces it to handlers as `ctx.auth` (see `Urchin.Context`), so a handler can make
  per-tool authorization decisions:

      def call_tool("delete", _args, ctx) do
        if Urchin.Auth.Claims.has_scope?(ctx.auth, "files:write") do
          # ...
        else
          {:error, "files:write scope required"}
        end
      end

  `from_map/1` converts a decoded JWT payload or an RFC 7662 introspection response into
  this struct, normalizing the OAuth/JWT field names (`sub`, `aud`, `scope`, `exp`, ...).
  """

  defstruct subject: nil,
            client_id: nil,
            expires_at: nil,
            scopes: [],
            audience: [],
            claims: %{}

  @type t :: %__MODULE__{
          subject: String.t() | nil,
          client_id: String.t() | nil,
          expires_at: integer() | nil,
          scopes: [String.t()],
          audience: [String.t()],
          claims: map()
        }

  @doc """
  Builds a `Claims` struct from a decoded token payload (string-keyed map).

  Recognized fields: `sub`, `client_id`/`azp`, `exp`, `aud` (string or list),
  `scope` (space-delimited string) and/or `scp`/`scopes` (string or list). The full
  payload is preserved under `:claims` for custom checks.
  """
  @spec from_map(map()) :: t()
  def from_map(payload) when is_map(payload) do
    %__MODULE__{
      subject: payload["sub"],
      client_id: payload["client_id"] || payload["azp"],
      expires_at: normalize_exp(payload["exp"]),
      scopes: extract_scopes(payload),
      audience: normalize_list(payload["aud"]),
      claims: payload
    }
  end

  @doc "Returns true when the claims grant the given scope."
  @spec has_scope?(t() | nil, String.t()) :: boolean()
  def has_scope?(%__MODULE__{scopes: scopes}, scope) when is_binary(scope) do
    scope in scopes
  end

  def has_scope?(nil, _scope), do: false

  @doc "Returns true when the claims grant every scope in `required`."
  @spec has_scopes?(t() | nil, [String.t()]) :: boolean()
  def has_scopes?(%__MODULE__{scopes: scopes}, required) when is_list(required) do
    Enum.all?(required, &(&1 in scopes))
  end

  def has_scopes?(nil, required), do: required == []

  # OAuth and JWT carry scopes under several names: a space-delimited "scope" string
  # (RFC 6749 / 7662), or "scp"/"scopes" as either a list or a string.
  defp extract_scopes(payload) do
    [payload["scope"], payload["scp"], payload["scopes"]]
    |> Enum.flat_map(&split_scope/1)
    |> Enum.uniq()
  end

  defp split_scope(nil), do: []
  defp split_scope(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp split_scope(value) when is_binary(value), do: String.split(value, " ", trim: true)
  defp split_scope(_), do: []

  defp normalize_list(nil), do: []
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_list(_), do: []

  defp normalize_exp(exp) when is_integer(exp), do: exp
  defp normalize_exp(exp) when is_float(exp), do: trunc(exp)
  defp normalize_exp(_), do: nil
end
