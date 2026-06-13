defmodule Urchin.Auth do
  @moduledoc """
  OAuth 2.1 Resource Server configuration and logic for the MCP authorization spec
  (revision 2025-11-25).

  Urchin acts purely as an OAuth 2.1 **Resource Server (RS)**: it delegates inbound
  access-token decisions to an injected authorizer and advertises the location of its
  Authorization Server(s) through RFC 9728 Protected Resource Metadata. The Authorization
  Server - the token, authorization and registration endpoints, PKCE, consent - is out of
  scope and may be any external entity.

  Authorization is **optional and off by default**. A transport mounted without `:auth`
  serves MCP unauthenticated, exactly as before. Pass an `Urchin.Auth` (or a keyword
  list coerced into one) to turn it on:

      auth =
        Urchin.Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          scopes_supported: ["mcp:tools", "files:read", "files:write"],
          authorizer: &MyApp.Auth.authorize/3
        )

      # one-call runner (also serves the well-known metadata endpoint):
      Urchin.start_link(MyServer, port: 4000, path: "/mcp", auth: auth)

      # or mounted as a Plug pipeline:
      plug Urchin.Auth.Metadata, auth: auth
      plug Urchin.Auth.Plug, auth: auth
      forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: MyServer]

  This module is the single source of truth: it builds the metadata document and the
  `WWW-Authenticate` challenges, and it invokes an injected authorizer. Request context is
  passed through as an opaque `conn` term so tenant/realm-aware callbacks can resolve
  per-request authorization data.

  ## Options (`new!/1`)

    * `:resource` (required) - the canonical server URI, e.g.
      `"https://mcp.example.com/mcp"`. Used as the metadata `resource` field. The
      configured authorizer should enforce this as the token audience/resource binding when
      RFC 8707 applies. MUST be absolute and MUST NOT carry a fragment.
    * `:authorization_servers` (required) - a non-empty list of AS issuer URLs, or a
      1-arity function `fn conn -> [issuer] end`, surfaced in the metadata document.
    * `:authorizer` (required) - a module implementing `Urchin.Auth.Authorizer`, or a
      3-arity function `fn token, auth, conn -> result end`. It owns the full authorization
      decision: token validity, issuer, expiry, audience, scopes and tenant policy.
    * `:scopes_supported` - optional list of scopes advertised in the metadata document.
    * `:required_scopes` - scopes every request should carry. A list, or a 1-arity function
      `fn conn -> [scope] end` for per-request requirements. Urchin uses this for challenge
      hints; the authorizer decides whether and how to enforce it. Default `[]`.
    * `:bearer_methods_supported` - default `["header"]` (MCP requires header tokens).
    * `:resource_name`, `:jwks_uri`, `:resource_documentation` - optional metadata fields.
    * `:resource_metadata_url` - optional absolute URL, or `fn conn -> url end`, used in
      `WWW-Authenticate: resource_metadata`. Defaults to the RFC 9728 well-known URL for
      `:resource`. Use a resolver to preserve tenant context in the challenge, e.g. by adding
      a query parameter (`?realm=...`). The metadata document is served only at the static
      well-known paths derived from `:resource`, so a resolver that points at a different path
      (e.g. a per-tenant path segment) must be served by your own route or an external host.
    * `:metadata` - a map of extra RFC 9728 fields. Reserved fields managed by Urchin
      cannot be overridden.
    * `:allow_insecure_authorization_servers` - permit non-HTTPS issuer URLs (localhost is
      always allowed). Default `false`.
  """

  require Logger

  alias Urchin.Auth.Claims

  @well_known "/.well-known/oauth-protected-resource"
  @allowed_options [
    :resource,
    :authorization_servers,
    :authorizer,
    :scopes_supported,
    :required_scopes,
    :bearer_methods_supported,
    :resource_name,
    :jwks_uri,
    :resource_documentation,
    :resource_metadata_url,
    :metadata,
    :allow_insecure_authorization_servers
  ]
  @deprecated_options [:token_validator, :audience_validation]
  @kinds [:missing, :invalid_token, :insufficient_scope, :invalid_request, :server_error]

  defstruct [
    :resource,
    :resource_uri,
    :resource_metadata_url,
    :resource_name,
    :jwks_uri,
    :resource_documentation,
    authorization_servers: [],
    authorizer: nil,
    scopes_supported: nil,
    required_scopes: [],
    well_known_paths: [],
    metadata: %{},
    bearer_methods_supported: ["header"],
    allow_insecure_authorization_servers: false
  ]

  @type authorization_servers :: [String.t()] | (term() -> [String.t()])
  @type resource_metadata_url :: String.t() | (term() -> String.t())

  @type authorizer ::
          module()
          | (token :: String.t() | nil, auth :: t(), conn :: term() ->
               Urchin.Auth.Authorizer.result())

  @type kind :: :missing | :invalid_token | :insufficient_scope | :invalid_request | :server_error

  @type t :: %__MODULE__{
          resource: String.t(),
          resource_uri: URI.t(),
          resource_metadata_url: resource_metadata_url(),
          resource_name: String.t() | nil,
          jwks_uri: String.t() | nil,
          resource_documentation: String.t() | nil,
          authorization_servers: authorization_servers(),
          authorizer: {:module, module()} | {:fun, fun()},
          scopes_supported: [String.t()] | nil,
          required_scopes: [String.t()] | (term() -> [String.t()]),
          well_known_paths: [String.t()],
          metadata: map(),
          bearer_methods_supported: [String.t()],
          allow_insecure_authorization_servers: boolean()
        }

  ## Construction

  @doc """
  Builds an `Urchin.Auth` from options, raising `ArgumentError` on invalid input.

  See the module documentation for the option list.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(opts) when is_map(opts), do: new!(Map.to_list(opts))

  def new!(opts) when is_list(opts) do
    validate_options!(opts)

    resource = require_opt!(opts, :resource)
    resource_uri = parse_resource!(resource)

    allow_insecure = Keyword.get(opts, :allow_insecure_authorization_servers, false)

    servers =
      opts
      |> require_opt!(:authorization_servers)
      |> resolve_authorization_servers!(allow_insecure)

    authorizer = opts |> require_opt!(:authorizer) |> resolve_authorizer!()
    suffix = path_suffix(resource_uri)
    resource_metadata_url = resolve_resource_metadata_url!(opts, resource_uri, suffix)
    metadata = opts |> Keyword.get(:metadata, %{}) |> validate_metadata!()
    required_scopes = opts |> Keyword.get(:required_scopes, []) |> resolve_required_scopes!()

    %__MODULE__{
      resource: resource,
      resource_uri: resource_uri,
      resource_metadata_url: resource_metadata_url,
      resource_name: Keyword.get(opts, :resource_name),
      jwks_uri: Keyword.get(opts, :jwks_uri),
      resource_documentation: Keyword.get(opts, :resource_documentation),
      authorization_servers: servers,
      authorizer: authorizer,
      scopes_supported: Keyword.get(opts, :scopes_supported),
      required_scopes: required_scopes,
      well_known_paths: Enum.uniq([@well_known <> suffix, @well_known]),
      metadata: metadata,
      bearer_methods_supported: Keyword.get(opts, :bearer_methods_supported, ["header"]),
      allow_insecure_authorization_servers: allow_insecure
    }
  end

  @doc "Like `new!/1`, but returns `{:ok, auth}` or `{:error, message}`."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) do
    {:ok, new!(opts)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc """
  Coerces a transport/plug `:auth` option into an `Urchin.Auth` (or `nil` when disabled).

  Accepts an existing struct, a keyword list / map of options, or `nil`.
  """
  @spec coerce!(t() | keyword() | map() | nil) :: t() | nil
  def coerce!(nil), do: nil
  def coerce!(%__MODULE__{} = auth), do: auth
  def coerce!(opts) when is_list(opts) or is_map(opts), do: new!(opts)

  def coerce!(other) do
    raise ArgumentError,
          ":auth must be an %Urchin.Auth{}, a keyword list or map of options, or nil, " <>
            "got: #{inspect(other)}"
  end

  ## Metadata (RFC 9728 discovery)

  @doc "Returns the RFC 9728 Protected Resource Metadata document as a JSON-encodable map."
  @spec metadata_document(t(), term()) :: map()
  def metadata_document(%__MODULE__{} = auth, conn) do
    %{
      resource: auth.resource,
      authorization_servers: authorization_servers(auth, conn),
      bearer_methods_supported: auth.bearer_methods_supported
    }
    |> put_optional(:scopes_supported, auth.scopes_supported)
    |> put_optional(:resource_name, auth.resource_name)
    |> put_optional(:jwks_uri, auth.jwks_uri)
    |> put_optional(:resource_documentation, auth.resource_documentation)
    |> Map.merge(auth.metadata)
  end

  @doc "Resolves the configured Authorization Server issuer URLs for the request."
  @spec authorization_servers(t(), term()) :: [String.t()]
  def authorization_servers(%__MODULE__{authorization_servers: fun} = auth, conn)
      when is_function(fun, 1) do
    fun.(conn)
    |> normalize_authorization_servers!(auth.allow_insecure_authorization_servers)
  end

  def authorization_servers(%__MODULE__{authorization_servers: servers}, _conn), do: servers

  @doc "The absolute URL of the Protected Resource Metadata document (for `resource_metadata`)."
  @spec resource_metadata_url(t(), term()) :: String.t()
  def resource_metadata_url(%__MODULE__{resource_metadata_url: fun}, conn)
      when is_function(fun, 1) do
    fun.(conn)
    |> validate_resource_metadata_url!()
  end

  def resource_metadata_url(%__MODULE__{resource_metadata_url: url}, _conn), do: url

  @doc "The request paths at which the metadata document is served (canonical + root)."
  @spec well_known_paths(t(), term()) :: [String.t()]
  def well_known_paths(%__MODULE__{well_known_paths: paths}, _conn), do: paths

  ## Request-time helpers

  @doc "Resolves the scopes required for a request (static list or `fn conn -> [...] end`)."
  @spec required_scopes(t(), term()) :: [String.t()]
  def required_scopes(%__MODULE__{required_scopes: fun}, conn) when is_function(fun, 1) do
    fun.(conn) |> normalize_scopes!(":required_scopes resolver")
  end

  def required_scopes(%__MODULE__{required_scopes: list}, _conn) when is_list(list), do: list

  @doc """
  Authorizes a bearer token (or its absence) against this configuration.

  Delegates the final decision to the configured authorizer. Returns `{:ok, claims}` or
  `{:error, kind, message}`, where `kind` selects the challenge (see `challenge/5`).
  """
  @spec authorize(t(), String.t() | nil, term()) ::
          {:ok, Claims.t()} | {:error, kind(), String.t()}
  def authorize(%__MODULE__{} = auth, token, conn) do
    case blank_to_nil(token) do
      nil ->
        # The SDK resolves a missing/blank bearer token, never the authorizer, so the
        # unauthenticated discovery bootstrap always gets the spec 401 challenge instead of a
        # 500 from an authorizer that lacks a nil clause.
        {:error, :missing, "Authorization required"}

      token ->
        auth.authorizer
        |> invoke_authorizer(token, auth, conn)
        |> normalize_result()
        |> warn_uncovered_resource(auth)
    end
  rescue
    error ->
      # A crashing authorizer must not leak internals or 200 a bad token; surface a 500.
      Logger.error("Urchin.Auth authorizer raised: #{Exception.message(error)}")
      {:error, :server_error, "Internal Server Error"}
  catch
    kind, reason ->
      Logger.error("Urchin.Auth authorizer threw: #{inspect({kind, reason})}")
      {:error, :server_error, "Internal Server Error"}
  end

  @doc """
  Builds the HTTP response for a failed authorization decision.

  Returns `{status, www_authenticate, body}` where `www_authenticate` is the header
  string (or `nil` for 500) and `body` is the OAuth 2.0 error object. The scope hint and
  `resource_metadata` URL are resolved here from the (possibly per-request) configuration;
  a resolver that raises degrades the header to a minimal challenge rather than escalating
  the response to a 500 with no `WWW-Authenticate`.
  """
  @spec challenge(t(), kind(), String.t(), term()) :: {100..599, String.t() | nil, map()}
  def challenge(%__MODULE__{} = auth, kind, message, conn) do
    {status_for(kind), safe_www_authenticate(auth, kind, message, conn),
     %{error: body_error_code(kind), error_description: message}}
  end

  ## Authorization pipeline

  defp invoke_authorizer({:module, mod}, token, auth, conn), do: mod.authorize(token, auth, conn)
  defp invoke_authorizer({:fun, fun}, token, auth, conn), do: fun.(token, auth, conn)

  defp normalize_result({:ok, %Claims{} = claims}), do: {:ok, claims}

  # Only a plain (non-struct) map is a token payload; a foreign struct is a programming error
  # and falls through to the unexpected-value clause instead of crashing inside from_map/1.
  defp normalize_result({:ok, map}) when is_map(map) and not is_struct(map),
    do: {:ok, Claims.from_map(map)}

  defp normalize_result({:error, kind, message})
       when kind in @kinds and is_binary(message),
       do: {:error, kind, message}

  defp normalize_result({:error, reason}), do: map_reason(reason)

  defp normalize_result(other) do
    Logger.error("Urchin.Auth authorizer returned an unexpected value: #{inspect(other)}")
    {:error, :server_error, "Internal Server Error"}
  end

  defp map_reason(:missing), do: {:error, :missing, "Authorization required"}
  defp map_reason(:expired), do: {:error, :invalid_token, "Token has expired"}
  defp map_reason(:invalid_audience), do: {:error, :invalid_token, "Token audience is invalid"}

  defp map_reason({:invalid_audience, _}),
    do: {:error, :invalid_token, "Token audience is invalid"}

  defp map_reason(:insufficient_scope), do: {:error, :insufficient_scope, "Insufficient scope"}

  defp map_reason({:insufficient_scope, _}),
    do: {:error, :insufficient_scope, "Insufficient scope"}

  defp map_reason(:invalid_request), do: {:error, :invalid_request, "Invalid request"}

  defp map_reason(reason) when reason in [:invalid_token, :invalid, :unauthorized],
    do: {:error, :invalid_token, "Invalid access token"}

  # A bare binary reason is a generic invalid-token rejection and is NOT reflected to the
  # client (it may carry internals). Use the {:error, kind, message} form to surface a
  # deliberately client-visible description.
  defp map_reason(message) when is_binary(message) do
    Logger.debug("Urchin.Auth authorizer rejected a token: #{message}")
    {:error, :invalid_token, "Invalid access token"}
  end

  defp map_reason(_other), do: {:error, :invalid_token, "Invalid access token"}

  defp warn_uncovered_resource({:ok, %Claims{audience: []} = claims}, _auth), do: {:ok, claims}

  defp warn_uncovered_resource({:ok, %Claims{} = claims}, auth) do
    unless Claims.covers_resource?(claims, auth.resource_uri) do
      Logger.warning(
        "Urchin.Auth authorizer returned claims whose audience does not cover #{auth.resource}"
      )
    end

    {:ok, claims}
  end

  defp warn_uncovered_resource(other, _auth), do: other

  ## WWW-Authenticate building

  # Per-request resolvers (`:resource_metadata_url`, `:required_scopes`) run while building
  # the error response. A raised or thrown resolver must not turn a 401/403 challenge into a
  # 500 with no header, so failures here degrade to a minimal but valid challenge.
  defp safe_www_authenticate(auth, kind, message, conn) do
    www_authenticate(auth, kind, message, safe_required_scopes(auth, conn), conn)
  rescue
    error ->
      Logger.error("Urchin.Auth challenge construction failed: #{Exception.message(error)}")
      minimal_challenge(kind)
  catch
    thrown, reason ->
      Logger.error("Urchin.Auth challenge construction threw: #{inspect({thrown, reason})}")
      minimal_challenge(kind)
  end

  # A failing scope resolver only costs the scope hint; keep the rest of the challenge.
  defp safe_required_scopes(auth, conn) do
    required_scopes(auth, conn)
  rescue
    error ->
      Logger.error(
        "Urchin.Auth :required_scopes resolver failed during challenge: #{Exception.message(error)}"
      )

      []
  catch
    thrown, reason ->
      Logger.error(
        "Urchin.Auth :required_scopes resolver threw during challenge: #{inspect({thrown, reason})}"
      )

      []
  end

  # Keep a failed challenge a valid 401/403 (never a 500 with no header) by dropping the
  # discovery hints rather than the whole response.
  defp minimal_challenge(:server_error), do: nil
  defp minimal_challenge(:missing), do: "Bearer"
  defp minimal_challenge(kind), do: build_bearer([{"error", body_error_code(kind)}])

  # No-credentials 401: per RFC 6750 §3.1 (and the MCP §6.1 example) the challenge omits
  # `error` when the request carried no authentication information.
  defp www_authenticate(auth, :missing, _message, scopes, conn) do
    build_bearer(
      [{"resource_metadata", resource_metadata_url(auth, conn)}] ++ scope_param(scopes)
    )
  end

  defp www_authenticate(auth, :invalid_token, message, scopes, conn) do
    build_bearer(
      [
        {"error", "invalid_token"},
        {"error_description", message},
        {"resource_metadata", resource_metadata_url(auth, conn)}
      ] ++ scope_param(scopes)
    )
  end

  defp www_authenticate(auth, :insufficient_scope, message, scopes, conn) do
    # The 403 SHOULD advertise the scopes needed for the request; if none were resolved for
    # this request (e.g. a validator-driven insufficient_scope), fall back to scopes_supported.
    hint = if scopes == [], do: auth.scopes_supported || [], else: scopes

    build_bearer(
      [{"error", "insufficient_scope"}] ++
        scope_param(hint) ++
        [
          {"resource_metadata", resource_metadata_url(auth, conn)},
          {"error_description", message}
        ]
    )
  end

  defp www_authenticate(auth, :invalid_request, message, _scopes, conn) do
    build_bearer([
      {"error", "invalid_request"},
      {"error_description", message},
      {"resource_metadata", resource_metadata_url(auth, conn)}
    ])
  end

  # Server errors are not the client's fault and carry no discovery hint.
  defp www_authenticate(_auth, :server_error, _message, _scopes, _conn), do: nil

  defp scope_param([]), do: []
  defp scope_param(scopes), do: [{"scope", Enum.join(scopes, " ")}]

  defp build_bearer(params) do
    "Bearer " <> Enum.map_join(params, ", ", fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
  end

  # auth-param values are quoted-strings (RFC 7235). Strip control characters first (a
  # bare CR/LF would otherwise make put_resp_header raise and turn the 401 into a 500),
  # then escape backslash and double-quote.
  defp escape(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp status_for(:missing), do: 401
  defp status_for(:invalid_token), do: 401
  defp status_for(:insufficient_scope), do: 403
  defp status_for(:invalid_request), do: 400
  defp status_for(:server_error), do: 500

  defp body_error_code(:missing), do: "invalid_token"
  defp body_error_code(:invalid_token), do: "invalid_token"
  defp body_error_code(:insufficient_scope), do: "insufficient_scope"
  defp body_error_code(:invalid_request), do: "invalid_request"
  defp body_error_code(:server_error), do: "server_error"

  ## URI helpers

  # Shared acceptance rule for every configured URI: an absolute http(s) URI with a
  # non-empty host. Callers layer their own fragment/query rules and error messages on top.
  defp parse_http_uri(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp parse_http_uri(_other), do: :error

  defp parse_resource!(resource) do
    case parse_http_uri(resource) do
      {:ok, uri} ->
        if uri.fragment, do: raise(ArgumentError, ":resource MUST NOT contain a fragment")
        uri

      :error ->
        raise ArgumentError,
              ":resource must be an absolute http(s) URI, got: #{inspect(resource)}"
    end
  end

  defp validate_issuer!(issuer, allow_insecure) do
    case parse_http_uri(issuer) do
      {:ok, uri} ->
        cond do
          uri.fragment ->
            raise ArgumentError,
                  "authorization server #{inspect(issuer)} MUST NOT contain a fragment"

          uri.query ->
            raise ArgumentError,
                  "authorization server #{inspect(issuer)} MUST NOT contain a query"

          uri.scheme == "http" and not (allow_insecure or localhost?(uri.host)) ->
            raise ArgumentError,
                  "authorization server #{inspect(issuer)} must be HTTPS " <>
                    "(set allow_insecure_authorization_servers: true to override)"

          true ->
            :ok
        end

      :error ->
        raise ArgumentError,
              "authorization server must be an absolute URI, got: #{inspect(issuer)}"
    end
  end

  defp resolve_authorization_servers!(fun, _allow_insecure) when is_function(fun, 1), do: fun

  defp resolve_authorization_servers!(servers, allow_insecure) do
    normalize_authorization_servers!(servers, allow_insecure)
  end

  defp normalize_authorization_servers!(servers, allow_insecure) do
    servers = List.wrap(servers)

    if servers == [],
      do: raise(ArgumentError, ":authorization_servers must list at least one issuer")

    Enum.each(servers, &validate_issuer!(&1, allow_insecure))
    servers
  end

  defp resolve_authorizer!(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :authorize, 3) do
      {:module, mod}
    else
      raise ArgumentError,
            ":authorizer module must implement authorize/3, got: #{inspect(mod)}"
    end
  end

  defp resolve_authorizer!(fun) when is_function(fun, 3), do: {:fun, fun}

  defp resolve_authorizer!(other) do
    raise ArgumentError,
          ":authorizer must be a module or a 3-arity function, got: #{inspect(other)}"
  end

  defp resolve_required_scopes!(fun) when is_function(fun, 1), do: fun

  defp resolve_required_scopes!(fun) when is_function(fun) do
    raise ArgumentError, ":required_scopes must be a list or a 1-arity function"
  end

  defp resolve_required_scopes!(scopes), do: normalize_scopes!(scopes, ":required_scopes")

  defp normalize_scopes!(scopes, name) do
    scopes = List.wrap(scopes)

    if Enum.all?(scopes, &is_binary/1) do
      scopes
    else
      raise ArgumentError, "#{name} must contain only strings, got: #{inspect(scopes)}"
    end
  end

  defp resolve_resource_metadata_url!(opts, resource_uri, suffix) do
    case Keyword.fetch(opts, :resource_metadata_url) do
      {:ok, fun} when is_function(fun, 1) ->
        fun

      {:ok, url} ->
        validate_resource_metadata_url!(url)

      :error ->
        build_metadata_url(resource_uri, suffix)
    end
  end

  defp validate_resource_metadata_url!(url) do
    case parse_http_uri(url) do
      {:ok, uri} ->
        if uri.fragment,
          do: raise(ArgumentError, ":resource_metadata_url MUST NOT contain a fragment")

        url

      :error ->
        raise ArgumentError,
              ":resource_metadata_url must be an absolute http(s) URI, got: #{inspect(url)}"
    end
  end

  # RFC 9728 §3.1 path insertion: the well-known suffix mirrors the resource path.
  defp path_suffix(%URI{path: path}) when path in [nil, "", "/"], do: ""
  defp path_suffix(%URI{path: path}), do: path

  # Rebuild from the parsed URI so IPv6 host bracketing, default-port elision and userinfo
  # stripping are handled by URI.to_string/1 (a hand-built authority mangles all three).
  defp build_metadata_url(%URI{} = uri, suffix) do
    %URI{uri | userinfo: nil, path: @well_known <> suffix, query: nil, fragment: nil}
    |> URI.to_string()
  end

  defp localhost?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  ## Misc

  @reserved_metadata_keys ~w[
    resource
    authorization_servers
    bearer_methods_supported
    scopes_supported
    resource_name
    jwks_uri
    resource_documentation
  ]

  defp validate_metadata!(metadata) when is_map(metadata) do
    case Enum.find(Map.keys(metadata), &(to_string(&1) in @reserved_metadata_keys)) do
      nil ->
        metadata

      key ->
        raise ArgumentError, ":metadata cannot override reserved field #{inspect(key)}"
    end
  end

  defp validate_metadata!(other),
    do: raise(ArgumentError, ":metadata must be a map, got: #{inspect(other)}")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(token), do: token

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Urchin.Auth options must be a keyword list or an atom-keyed map"
    end

    case Enum.find(Keyword.keys(opts), &(&1 in @deprecated_options)) do
      nil ->
        :ok

      :token_validator ->
        raise ArgumentError, ":token_validator was removed; use :authorizer instead"

      :audience_validation ->
        raise ArgumentError,
              ":audience_validation was removed; enforce audience/resource binding in :authorizer"
    end

    case Enum.find(Keyword.keys(opts), &(&1 not in @allowed_options)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown Urchin.Auth option #{inspect(key)}"
    end
  end

  defp require_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Urchin.Auth requires the #{inspect(key)} option"
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
