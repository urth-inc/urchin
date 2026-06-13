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
  Builds a `Claims` struct from a decoded token payload (string- or atom-keyed map).

  Recognized fields: `sub`, `client_id`/`azp`, `exp`, `aud` (string or list),
  `scope` (space-delimited string) and/or `scp`/`scopes` (string or list). JWT and RFC 7662
  payloads are string-keyed, but an authorizer that hand-builds an atom-keyed map is also
  accepted. The full payload is preserved under `:claims` for custom checks.
  """
  @spec from_map(map()) :: t()
  def from_map(payload) when is_map(payload) do
    %__MODULE__{
      subject: get_field(payload, "sub", :sub),
      client_id: get_field(payload, "client_id", :client_id) || get_field(payload, "azp", :azp),
      expires_at: normalize_exp(get_field(payload, "exp", :exp)),
      scopes: extract_scopes(payload),
      audience: normalize_list(get_field(payload, "aud", :aud)),
      claims: payload
    }
  end

  # Token payloads come string-keyed from JSON decoding, but accept the atom-keyed form an
  # authorizer might build by hand so its claims are not silently dropped.
  defp get_field(payload, string_key, atom_key) do
    case payload do
      %{^string_key => value} -> value
      %{^atom_key => value} -> value
      _ -> nil
    end
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

  @doc """
  Returns true when any token audience covers the configured resource URI.

  The comparison follows the resource binding semantics Urchin used before the
  authorizer handoff: the audience must share the same scheme, host and effective port,
  and its path may be the resource path itself or a parent path. For example, an audience
  of `https://mcp.example.com` covers `https://mcp.example.com/mcp`, but
  `https://mcp.example.com/other` does not.
  """
  @spec covers_resource?(t() | nil, String.t() | URI.t()) :: boolean()
  def covers_resource?(%__MODULE__{audience: audiences}, resource) when is_list(audiences) do
    with {:ok, resource_uri} <- resource_uri(resource) do
      Enum.any?(audiences, &audience_covers?(resource_uri, &1))
    else
      :error -> false
    end
  end

  # A malformed (non-list) audience covers nothing rather than crashing the caller.
  def covers_resource?(%__MODULE__{}, _resource), do: false

  def covers_resource?(nil, _resource), do: false

  defp resource_uri(%URI{} = uri), do: {:ok, uri}

  defp resource_uri(resource) when is_binary(resource) do
    case URI.new(resource) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp resource_uri(_other), do: :error

  defp audience_covers?(%URI{} = resource_uri, audience) when is_binary(audience) do
    case URI.new(audience) do
      {:ok, %URI{} = aud_uri} ->
        same_origin?(resource_uri, aud_uri) and path_within?(resource_uri.path, aud_uri.path)

      _ ->
        false
    end
  end

  defp audience_covers?(_resource_uri, _audience), do: false

  defp same_origin?(a, b) do
    downcase(a.scheme) == downcase(b.scheme) and
      downcase(a.host) == downcase(b.host) and
      effective_port(a) == effective_port(b)
  end

  defp effective_port(%URI{scheme: scheme, port: nil}), do: default_port(scheme)
  defp effective_port(%URI{port: port}), do: port

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: nil

  defp path_within?(resource_path, audience_path) do
    String.starts_with?(with_trailing(resource_path), with_trailing(audience_path))
  end

  defp with_trailing(path) when path in [nil, ""], do: "/"
  defp with_trailing(path), do: if(String.ends_with?(path, "/"), do: path, else: path <> "/")

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  # OAuth and JWT carry scopes under several names: a space-delimited "scope" string
  # (RFC 6749 / 7662), or "scp"/"scopes" as either a list or a string.
  defp extract_scopes(payload) do
    [
      get_field(payload, "scope", :scope),
      get_field(payload, "scp", :scp),
      get_field(payload, "scopes", :scopes)
    ]
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
