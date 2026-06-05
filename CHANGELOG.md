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
