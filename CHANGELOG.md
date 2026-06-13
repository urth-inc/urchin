# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-06-11

This release makes the server enforce the MCP specification by default. Several behaviors
that were previously absent or lenient are now always on; see Changed for the breaking
details and how to adapt.

### Added

- Session lifecycle limits: `:max_sessions` (reject new sessions with `503` past a cap —
  enforced atomically, before the server's `init/1` runs, so a rejected session pays no
  init cost and the cap holds under concurrent initializes), `:session_idle_timeout`
  (terminate after inactivity; a session serving a request is not reaped) and
  `:session_max_lifetime` (terminate a fixed time after creation). All default to `nil`
  (unlimited) and are validated as positive integers at startup. Session processes are now
  `restart: :temporary` so an ended session is never resurrected under its old id.
- Declarative tool scopes: `tool "name", scopes: ["files:write"], ...` enforces the scopes
  against `ctx.auth` before the handler runs, failing closed when the request carries no
  authorization.
- `:expose_internal_errors` transport option (default `false`). Unexpected exceptions and
  malformed handler returns are now logged in full but return a generic message to the
  client; enable the option to surface the detail in development. Deliberate `Urchin.Error`
  values and `{:error, message}` returns are never redacted — their `message`/`data` reach the
  client unchanged.
- Capability guards: `Urchin.Context.create_message/3`, `elicit/3` and `list_roots/2`
  return an error without contacting the client when it did not advertise the matching
  `sampling`/`elicitation`/`roots` capability.
- `415 Unsupported Media Type` for POST requests whose `Content-Type` is not
  `application/json`.
- `SECURITY.md` with a threat model, deployment checklist and vulnerability reporting.
- `:sse_buffer_limit` transport option (default `nil`, preserving the session's internal
  default of `100`) forwarding the per-session GET-stream replay buffer size to the session;
  previously only configurable on `Urchin.Session` directly.
- Per-request OAuth authorization server resolution: `authorization_servers` may now be a
  `fn conn -> [issuer] end` resolver, allowing tenant/realm-aware Protected Resource
  Metadata. Token audience/resource binding is owned by the configured authorizer.
- Per-request OAuth protected resource metadata URL resolution via `resource_metadata_url:
  fn conn -> url end`, allowing `WWW-Authenticate` challenges to preserve tenant context
  (e.g. a `?realm=...` query parameter) for the follow-up metadata request. The discovery
  document is served only at the static well-known paths derived from `:resource`; a resolver
  that points at a different path (e.g. a per-tenant path segment) must be served by your own
  route or an external host.

### Changed

The following are now enforced by default, with no opt-out, for MCP spec compliance. They are
breaking relative to `0.2.0`.

- A DSL tool's `tools/call` arguments are validated against its `input_schema` before the
  handler runs; a mismatch is returned as a `CallToolResult` with `isError: true` so the model
  can self-correct. A tool that declares no `input_schema` now defaults to an object that
  accepts no properties (`additionalProperties: false`), so unexpected arguments are rejected —
  declare an explicit `input_schema` to accept arbitrary fields. A non-object `arguments` value
  is a malformed request and remains a JSON-RPC `invalid_params` error. Servers that implement
  `call_tool/3` by hand validate their own arguments. `Urchin.Schema` implements the supported
  (minimal) JSON Schema subset.
- Operation requests received before the client sends `notifications/initialized` are rejected
  with `invalid_request`; only `ping` is allowed before initialization (the lifecycle's
  pings-and-logging exception is for the server's own requests, not the client's
  `logging/setLevel`). Clients must complete the lifecycle handshake before issuing other
  requests.
- A `tools/call` handler's `{:error, message}` (string) is returned as a `CallToolResult` with
  `isError: true` so the model can self-correct. A protocol error returned as
  `{:error, %Urchin.Error{}}` is always a JSON-RPC error. (Previously a string handler error
  became a JSON-RPC internal error.)
- Duplicate literal tool names within a server are rejected at compile time (a silently shadowed
  duplicate was previously accepted, with the last declaration winning); non-literal names (a
  variable or expression) cannot be compared statically and are not checked. Urchin enforces no
  tool-name pattern (the MCP schema imposes none); servers should still follow the MCP naming
  recommendations.
- `initialize` requires `protocolVersion` (string), `capabilities` (object) and `clientInfo`
  (with a string `name` and `version`); a missing or mistyped field is an `invalid_params`
  error rather than a silently-defaulted value. The server's `serverInfo` must likewise carry a
  string `name` and `version`.
- The `MCP-Protocol-Version` header is validated on `DELETE`, matching `POST` and `GET`.
- `completion/complete` request params are validated (`ref` as a `ref/prompt`/`ref/resource`
  union, `argument.name`/`value` as strings, `context.arguments` values as strings) and return
  `invalid_params` when malformed. Results are capped at 100 values — a handler returning more is
  truncated to the top 100 (already ranked by relevance) with `hasMore` set — and a
  non-conforming result shape (non-string `values`, etc.) is an internal error.
- A tool's `input_schema` and `output_schema` must be JSON Schema objects whose root `type` is
  `"object"` (per the MCP tools spec); the DSL rejects a non-conforming schema at compile time.
- `logging/setLevel` is now a library builtin: when the server advertises the `logging`
  capability (via `use Urchin.Server, logging: true`) it succeeds and applies the level to the
  session even without a `set_log_level/2` callback. The level is validated against the MCP log
  levels (`invalid_params` otherwise), an exported `set_log_level/2` still runs as a hook, and
  the session level is updated only after the hook succeeds. Servers that do not advertise
  `logging` return `method_not_found`.
- `Urchin.Auth` now delegates the full request authorization decision to an injected
  `Urchin.Auth.Authorizer` (`authorize/3`) or 3-arity function. Urchin extracts bearer
  tokens, serves metadata, builds `WWW-Authenticate` challenges and passes claims to
  handlers; token validity, expiry, issuer, audience/resource binding, scopes and tenant
  policy are owned by the authorizer. A missing or blank token is resolved by Urchin to a
  `401` `:missing` challenge before the authorizer runs, so the authorizer is only invoked
  with a non-empty token and the unauthenticated discovery bootstrap always gets the spec
  challenge.
- **BREAKING / SECURITY:** Urchin no longer performs SDK-level expiry, audience/resource
  binding or request-scope enforcement after a token callback succeeds. Migrating
  applications must implement those checks inside their authorizer (for example using
  `Urchin.Auth.Claims.covers_resource?/2` and `has_scopes?/2`).
- `Urchin.Auth.new!/1` now rejects removed options such as `:token_validator` and
  `:audience_validation`, and rejects unknown options instead of silently ignoring them.
- `Urchin.Auth.Authorizer` may return `{:ok, map}` for migration compatibility; Urchin
  normalizes the map (string- or atom-keyed) through `Urchin.Auth.Claims.from_map/1`. A
  foreign struct returned in `{:ok, ...}` is reported as a server error rather than crashing
  the authorization pipeline.
- Authorization server issuer URLs now reject query strings in addition to fragments.
- Extra `:metadata` fields may no longer override fields owned by Urchin, such as
  `resource` and `authorization_servers`.
- Protected Resource Metadata responses now include `Cache-Control: no-store`.

### Fixed

- README no longer claims unqualified "resumable SSE streams"; resumption is scoped to the
  GET stream, matching the implementation.
- A per-request `:resource_metadata_url` or `:required_scopes` resolver that raises while a
  `WWW-Authenticate` challenge is being built no longer escalates the `401`/`403` into a
  `500` with no challenge; the challenge degrades to a valid header without the failed hint,
  and the failure is logged. The scope hint is also resolved only when a challenge is built,
  not on every successful request.

## [0.2.0] - 2026-06-05

### Added

- Optional OAuth 2.1 authorization (`Urchin.Auth`). Urchin can act as an OAuth 2.1
  resource server: RFC 9728 Protected Resource Metadata discovery (served at the
  well-known URI and advertised via `WWW-Authenticate: resource_metadata`), pluggable
  token validation (`Urchin.Auth.TokenValidator`), RFC 8707 audience binding, scope
  enforcement and `401`/`403`/`400` challenges. Enable it with the `:auth` option on the
  transport, `Urchin.Endpoint` or `Urchin.start_link/2`, or compose the
  `Urchin.Auth.Plug` and `Urchin.Auth.Metadata` plugs. Validated claims reach handlers as
  `ctx.auth`. Authorization remains off by default.

## [0.1.0] - 2026-06-04

Initial release: a Model Context Protocol (MCP) server library implementing the
`2025-11-25` specification over the Streamable HTTP transport.

### Added

- Server authoring via the `Urchin.Server` behaviour and a
  `tool`/`resource`/`resource_template`/`prompt` DSL with automatic capability
  derivation.
- Tools, resources (plus templates and subscriptions), prompts, completion and
  logging.
- Server-initiated requests over SSE: sampling, elicitation and roots.
- Progress notifications, cancellation, pagination and resumable SSE streams.
- A mountable `Plug` (`Urchin.Transport.StreamableHTTP`) and a standalone Bandit
  endpoint (`Urchin.Endpoint`, `Urchin.start_link/2`), plus `Urchin.broadcast/2`
  for fan-out notifications.

[0.2.0]: https://github.com/urth-inc/urchin/releases/tag/v0.2.0
[0.1.0]: https://github.com/urth-inc/urchin/releases/tag/v0.1.0
