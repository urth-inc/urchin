# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `:validate_arguments` transport option (default `false`) validates `tools/call` arguments
  against each DSL tool's `input_schema` and rejects a mismatch with `invalid_params` before
  the handler runs. `Urchin.Schema` implements the supported (minimal) JSON Schema subset.
- `:expose_internal_errors` transport option (default `false`). Unexpected exceptions and
  malformed handler returns are now logged in full but return a generic message to the
  client; enable the option to surface the detail in development. Deliberate `Urchin.Error`
  values and `{:error, message}` returns still pass through unchanged.
- Capability guards: `Urchin.Context.create_message/3`, `elicit/3` and `list_roots/2`
  return an error without contacting the client when it did not advertise the matching
  `sampling`/`elicitation`/`roots` capability.
- `415 Unsupported Media Type` for POST requests whose `Content-Type` is not
  `application/json`.
- `SECURITY.md` with a threat model, deployment checklist and vulnerability reporting.
- `:enforce_initialized` transport option (default `false`) rejecting operation requests
  received before the client sends `notifications/initialized` with `invalid_request`;
  `ping` and `logging/setLevel` are always allowed. The default may be flipped to `true` in
  a future minor release.
- `:tool_errors` transport option (`:json_rpc` default | `:result`). With `:result`, a
  `tools/call` handler's `{:error, message}` (string) is returned as a `CallToolResult` with
  `isError: true` so the model can self-correct, instead of a JSON-RPC internal error. A
  protocol error returned as `{:error, %Urchin.Error{}}` is always a JSON-RPC error.
- `validate_tool_names: true` option for `use Urchin.Server` enforcing, at compile time, that
  every literal tool name matches `~r/^[a-zA-Z0-9_.-]{1,128}$/` (default `false`).
- `:sse_buffer_limit` transport option (default `100`) forwarding the per-session GET-stream
  replay buffer size to the session; previously only configurable on `Urchin.Session`
  directly.

### Changed

- `logging/setLevel` is now a library builtin: advertising the `logging` capability (via
  `use Urchin.Server, logging: true`) makes `logging/setLevel` succeed and apply the level to
  the session even when the server does not export `set_log_level/2`. An exported
  `set_log_level/2` is still invoked as a hook.

### Fixed

- Duplicate tool names within a server are now rejected at compile time (a silently shadowed
  duplicate was previously accepted, with the last declaration winning).
- README no longer claims unqualified "resumable SSE streams"; resumption is scoped to the
  GET stream, matching the implementation.

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
