defmodule Urchin.Auth do
  @moduledoc """
  OAuth 2.1 Resource Server configuration and logic for the MCP authorization spec
  (revision 2025-11-25).

  Urchin acts purely as an OAuth 2.1 **Resource Server (RS)**: it validates inbound
  access tokens and advertises the location of its Authorization Server(s) through
  RFC 9728 Protected Resource Metadata. The Authorization Server — the token,
  authorization and registration endpoints, PKCE, consent — is out of scope and may be
  any external entity.

  Authorization is **optional and off by default**. A transport mounted without `:auth`
  serves MCP unauthenticated, exactly as before. Pass an `Urchin.Auth` (or a keyword
  list coerced into one) to turn it on:

      auth =
        Urchin.Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          scopes_supported: ["mcp:tools", "files:read", "files:write"],
          token_validator: &MyApp.Tokens.validate/3
        )

      # one-call runner (also serves the well-known metadata endpoint):
      Urchin.start_link(MyServer, port: 4000, path: "/mcp", auth: auth)

      # or mounted as a Plug pipeline:
      plug Urchin.Auth.Metadata, auth: auth
      plug Urchin.Auth.Plug, auth: auth
      forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: MyServer]

  This module is the single source of truth: it builds the metadata document and the
  `WWW-Authenticate` challenges, and it runs token validation (`verify_token/4`). Request
  context is passed through as an opaque `conn` term so tenant/realm-aware callbacks can
  resolve per-request authorization data.

  ## Options (`new!/1`)

    * `:resource` (required) - the canonical server URI, e.g.
      `"https://mcp.example.com/mcp"`. Used as the metadata `resource` field and as the
      expected token audience (RFC 8707). MUST be absolute and MUST NOT carry a fragment.
    * `:authorization_servers` (required) - a non-empty list of AS issuer URLs, or a
      1-arity function `fn conn -> [issuer] end`, surfaced in the metadata document.
    * `:token_validator` (required) - a module implementing `Urchin.Auth.TokenValidator`,
      or a 3-arity function `fn token, auth, conn -> result end`. See that module for the
      contract.
    * `:scopes_supported` - optional list of scopes advertised in the metadata document.
    * `:required_scopes` - scopes every request must carry. A list, or a 1-arity function
      `fn conn -> [scope] end` for per-request requirements. Default `[]`.
    * `:audience_validation` - `:auto` (default) enforces RFC 8707 binding: the token must
      carry an audience that includes `:resource`, and a token with no audience is rejected.
      An audience that is a parent path of `:resource` on the same origin (e.g. the bare
      origin) is accepted, so do not distinguish multiple servers by path alone on a shared
      origin. `:skip` performs no audience check and defers entirely to the validator (use
      it for opaque tokens whose audience the validator verifies itself).
    * `:bearer_methods_supported` - default `["header"]` (MCP requires header tokens).
    * `:resource_name`, `:jwks_uri`, `:resource_documentation` - optional metadata fields.
    * `:metadata` - a map of extra RFC 9728 fields merged into the document last.
    * `:allow_insecure_authorization_servers` - permit non-HTTPS issuer URLs (localhost is
      always allowed). Default `false`.
  """

  require Logger

  alias Urchin.Auth.Claims

  @well_known "/.well-known/oauth-protected-resource"

  defstruct [
    :resource,
    :resource_uri,
    :resource_metadata_url,
    :resource_name,
    :jwks_uri,
    :resource_documentation,
    authorization_servers: [],
    token_validator: nil,
    scopes_supported: nil,
    required_scopes: [],
    well_known_paths: [],
    metadata: %{},
    audience_validation: :auto,
    bearer_methods_supported: ["header"],
    allow_insecure_authorization_servers: false
  ]

  @type authorization_servers :: [String.t()] | (term() -> [String.t()])

  @type validator ::
          module()
          | (token :: String.t(), auth :: t(), conn :: term() ->
               Urchin.Auth.TokenValidator.result())

  @type kind :: :missing | :invalid_token | :insufficient_scope | :invalid_request | :server_error

  @type t :: %__MODULE__{
          resource: String.t(),
          resource_uri: URI.t(),
          resource_metadata_url: String.t(),
          resource_name: String.t() | nil,
          jwks_uri: String.t() | nil,
          resource_documentation: String.t() | nil,
          authorization_servers: authorization_servers(),
          token_validator: {:module, module()} | {:fun, fun()},
          scopes_supported: [String.t()] | nil,
          required_scopes: [String.t()] | (term() -> [String.t()]),
          well_known_paths: [String.t()],
          metadata: map(),
          audience_validation: :auto | :skip,
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
    resource = require_opt!(opts, :resource)
    resource_uri = parse_resource!(resource)

    allow_insecure = Keyword.get(opts, :allow_insecure_authorization_servers, false)

    servers =
      opts
      |> require_opt!(:authorization_servers)
      |> resolve_authorization_servers!(allow_insecure)

    validator = opts |> require_opt!(:token_validator) |> resolve_validator!()
    suffix = path_suffix(resource_uri)

    %__MODULE__{
      resource: resource,
      resource_uri: resource_uri,
      resource_metadata_url: build_metadata_url(resource_uri, suffix),
      resource_name: Keyword.get(opts, :resource_name),
      jwks_uri: Keyword.get(opts, :jwks_uri),
      resource_documentation: Keyword.get(opts, :resource_documentation),
      authorization_servers: servers,
      token_validator: validator,
      scopes_supported: Keyword.get(opts, :scopes_supported),
      required_scopes: Keyword.get(opts, :required_scopes, []),
      well_known_paths: Enum.uniq([@well_known <> suffix, @well_known]),
      metadata: Keyword.get(opts, :metadata, %{}),
      audience_validation: Keyword.get(opts, :audience_validation, :auto),
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
  def resource_metadata_url(%__MODULE__{resource_metadata_url: url}, _conn), do: url

  @doc "The request paths at which the metadata document is served (canonical + root)."
  @spec well_known_paths(t(), term()) :: [String.t()]
  def well_known_paths(%__MODULE__{well_known_paths: paths}, _conn), do: paths

  ## Request-time helpers

  @doc "Resolves the scopes required for a request (static list or `fn conn -> [...] end`)."
  @spec required_scopes(t(), term()) :: [String.t()]
  def required_scopes(%__MODULE__{required_scopes: fun}, conn) when is_function(fun, 1) do
    fun.(conn) |> List.wrap()
  end

  def required_scopes(%__MODULE__{required_scopes: list}, _conn) when is_list(list), do: list

  @doc """
  Validates a bearer token (or its absence) against this configuration.

  Runs the validator, then enforces token expiry (when exposed), audience binding
  (RFC 8707) and `required_scopes`. Returns `{:ok, claims}` or `{:error, kind, message}`,
  where `kind` selects the challenge (see `challenge/5`).
  """
  @spec verify_token(t(), String.t() | nil, [String.t()], term()) ::
          {:ok, Claims.t()} | {:error, kind(), String.t()}
  def verify_token(_auth, nil, _required, _conn), do: {:error, :missing, "Authorization required"}
  def verify_token(_auth, "", _required, _conn), do: {:error, :missing, "Authorization required"}

  def verify_token(%__MODULE__{} = auth, token, required_scopes, conn) when is_binary(token) do
    with {:ok, claims} <- run_validator(auth, token, conn),
         :ok <- check_expiry(claims),
         :ok <- check_audience(auth, claims),
         :ok <- check_scopes(claims, required_scopes) do
      {:ok, claims}
    end
  end

  @doc """
  Builds the HTTP response for a failed `verify_token/4`.

  Returns `{status, www_authenticate, body}` where `www_authenticate` is the header
  string (or `nil` for 500) and `body` is the OAuth 2.0 error object.
  """
  @spec challenge(t(), kind(), String.t(), [String.t()], term()) ::
          {100..599, String.t() | nil, map()}
  def challenge(%__MODULE__{} = auth, kind, message, required_scopes, conn) do
    {status_for(kind), www_authenticate(auth, kind, message, required_scopes, conn),
     %{error: body_error_code(kind), error_description: message}}
  end

  ## Validation pipeline

  defp run_validator(auth, token, conn) do
    auth.token_validator
    |> invoke(token, auth, conn)
    |> normalize_result()
  rescue
    error ->
      # A crashing validator must not leak internals or 200 a bad token; surface a 500.
      Logger.error("Urchin.Auth token validator raised: #{Exception.message(error)}")
      {:error, :server_error, "Internal Server Error"}
  catch
    kind, reason ->
      Logger.error("Urchin.Auth token validator threw: #{inspect({kind, reason})}")
      {:error, :server_error, "Internal Server Error"}
  end

  defp invoke({:module, mod}, token, auth, conn), do: mod.validate(token, auth, conn)
  defp invoke({:fun, fun}, token, auth, conn), do: fun.(token, auth, conn)

  defp normalize_result({:ok, %Claims{} = claims}), do: {:ok, claims}
  defp normalize_result({:ok, map}) when is_map(map), do: {:ok, Claims.from_map(map)}

  defp normalize_result({:error, kind, message})
       when kind in [:invalid_token, :insufficient_scope, :invalid_request, :server_error] and
              is_binary(message),
       do: {:error, kind, message}

  defp normalize_result({:error, reason}), do: map_reason(reason)

  defp normalize_result(other) do
    Logger.error("Urchin.Auth token validator returned an unexpected value: #{inspect(other)}")
    {:error, :server_error, "Internal Server Error"}
  end

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
    Logger.debug("Urchin.Auth token validator rejected a token: #{message}")
    {:error, :invalid_token, "Invalid access token"}
  end

  defp map_reason(_other), do: {:error, :invalid_token, "Invalid access token"}

  defp check_expiry(%Claims{expires_at: nil}), do: :ok

  defp check_expiry(%Claims{expires_at: exp}) when is_integer(exp) do
    if exp <= System.os_time(:second),
      do: {:error, :invalid_token, "Token has expired"},
      else: :ok
  end

  # Audience binding (RFC 8707): a token MUST be intended for this resource. :skip defers
  # the check entirely to the validator; :auto (the default) fails closed — a token with no
  # audience cannot be bound to this resource, so it is rejected rather than waved through.
  defp check_audience(%__MODULE__{audience_validation: :skip}, _claims), do: :ok

  defp check_audience(%__MODULE__{}, %Claims{audience: []}) do
    {:error, :invalid_token, "Token is not bound to this resource (no audience)"}
  end

  defp check_audience(%__MODULE__{} = auth, %Claims{audience: audiences}) do
    if Enum.any?(audiences, &audience_allowed?(auth.resource_uri, &1)) do
      :ok
    else
      {:error, :invalid_token, "Token audience does not include this resource"}
    end
  end

  defp check_scopes(_claims, []), do: :ok

  defp check_scopes(claims, required) do
    if Claims.has_scopes?(claims, required),
      do: :ok,
      else: {:error, :insufficient_scope, "Insufficient scope"}
  end

  ## WWW-Authenticate building

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

  defp parse_resource!(resource) when is_binary(resource) do
    case URI.new(resource) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if uri.fragment, do: raise(ArgumentError, ":resource MUST NOT contain a fragment")
        uri

      _ ->
        raise ArgumentError,
              ":resource must be an absolute http(s) URI, got: #{inspect(resource)}"
    end
  end

  defp parse_resource!(other),
    do: raise(ArgumentError, ":resource must be a string, got: #{inspect(other)}")

  defp validate_issuer!(issuer, allow_insecure) when is_binary(issuer) do
    case URI.new(issuer) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        cond do
          uri.fragment ->
            raise ArgumentError,
                  "authorization server #{inspect(issuer)} MUST NOT contain a fragment"

          scheme == "http" and not (allow_insecure or localhost?(host)) ->
            raise ArgumentError,
                  "authorization server #{inspect(issuer)} must be HTTPS " <>
                    "(set allow_insecure_authorization_servers: true to override)"

          true ->
            :ok
        end

      _ ->
        raise ArgumentError,
              "authorization server must be an absolute URI, got: #{inspect(issuer)}"
    end
  end

  defp validate_issuer!(other, _allow_insecure),
    do: raise(ArgumentError, "authorization server must be a string, got: #{inspect(other)}")

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

  defp resolve_validator!(mod) when is_atom(mod) and not is_nil(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :validate, 3) do
      {:module, mod}
    else
      raise ArgumentError,
            ":token_validator module must implement validate/3, got: #{inspect(mod)}"
    end
  end

  defp resolve_validator!(fun) when is_function(fun, 3), do: {:fun, fun}

  defp resolve_validator!(other) do
    raise ArgumentError,
          ":token_validator must be a module or a 3-arity function, got: #{inspect(other)}"
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

  defp audience_allowed?(%URI{} = resource_uri, audience) when is_binary(audience) do
    case URI.new(audience) do
      {:ok, %URI{} = aud_uri} ->
        same_origin?(resource_uri, aud_uri) and
          path_within?(resource_uri.path, aud_uri.path)

      _ ->
        false
    end
  end

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

  # The token's audience covers this resource when the resource path is at or below it.
  defp path_within?(resource_path, audience_path) do
    String.starts_with?(with_trailing(resource_path), with_trailing(audience_path))
  end

  defp with_trailing(path) when path in [nil, ""], do: "/"
  defp with_trailing(path), do: if(String.ends_with?(path, "/"), do: path, else: path <> "/")

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp localhost?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  ## Misc

  defp require_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Urchin.Auth requires the #{inspect(key)} option"
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
