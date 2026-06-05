# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `:expose_internal_errors` transport option (default `false`). Raised exceptions in
  handlers are now logged in full but return a generic message to the client; enable the
  option to surface exception messages in development.
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
