# Security Policy

Urchin is a Model Context Protocol (MCP) **server** library. It implements the transport
and protocol; the surrounding deployment (network exposure, TLS, an authorization server,
rate limiting) is the operator's responsibility. This document describes what Urchin does
and does not protect against, and what you must add before exposing a server publicly.

## What Urchin provides

- **Origin validation** (DNS-rebinding protection). By default only missing-Origin and
  localhost are allowed; configure `:allowed_origins` for browser clients.
- **Cryptographically random session ids** (`MCP-Session-Id`), visible-ASCII only.
- **OAuth 2.1 resource-server authorization** (optional, off by default). When enabled, it
  validates bearer tokens on every request, enforces RFC 8707 audience binding (fail-closed
  for tokens with no audience), checks scopes, and serves RFC 9728 discovery. See
  `Urchin.Auth`. The authorization server itself is external and out of scope.
- **Error redaction.** Unexpected exceptions and malformed handler returns are logged in
  full and replaced with a generic message before reaching clients (`:expose_internal_errors`,
  default `false`, opts into the detail for development). Deliberate errors — `Urchin.Error`
  values and `{:error, message}` returns — are not redacted; their `message`/`data` reach the
  client unchanged, so keep secrets and internals out of them. For `tools/call`, a string
  `{:error, message}` is surfaced as a `CallToolResult` with `isError: true` rather than a
  JSON-RPC error.
- **Capability-gated server-initiated requests.** `sampling/createMessage`,
  `elicitation/create` and `roots/list` are only sent when the client advertised the
  capability.
- **Declarative per-tool scopes.** `tool "name", scopes: [...]` enforces scopes against
  `ctx.auth` before the handler runs, failing closed when the request carries no
  authorization (only meaningful when `ctx.auth` is populated, typically by `:auth` or an
  upstream `Urchin.Auth.Plug`).
- **Argument validation.** A DSL tool's `tools/call` arguments are validated against its
  `input_schema` before the handler runs (a hand-written `call_tool/3` validates its own
  arguments). It is a minimal subset of JSON Schema (see `Urchin.Schema`), so unsupported
  keywords and `output_schema` are still your handler's responsibility.
- **Bounded request bodies** (`@max_body`, ~8 MB) and a per-request handler timeout.
- **Session lifecycle limits** (opt-in): `:max_sessions`, `:session_idle_timeout` and
  `:session_max_lifetime`. Without them a session persists until the client sends `DELETE`,
  so configure them on any public endpoint to avoid exhaustion.

## What you must add before public exposure

Urchin does **not** yet provide these; supply them in your deployment:

1. **TLS.** Terminate HTTPS at a reverse proxy or the endpoint. OAuth requires HTTPS in
   production.
2. **Authorization.** Set `:auth` (or front the transport with `Urchin.Auth.Plug`). An
   unauthenticated server bound to a public interface exposes every tool to anyone.
3. **Rate limiting / per-session concurrency limits.** Per IP, per session, and for
   `initialize` and long-running tools. (Session count and lifetime are covered by the
   built-in limits above; request-rate and in-flight caps are not yet built in.)
4. **Per-tool authorization beyond scopes.** Declarative `scopes:` covers scope checks;
   add app-specific authorization (ownership, tenancy, row-level access) in handlers via
   `ctx.auth`.
5. **Full input validation.** Structural checks against `input_schema` run automatically, but
   validate unsupported JSON Schema keywords, business rules and `output_schema` in your
   handler — `Urchin.Schema` is a minimal subset.

## Deployment checklist

- [ ] HTTPS only; redirect URIs are `localhost` or HTTPS.
- [ ] `:auth` configured with an `authorizer` that verifies signature/introspection, expiry,
      issuer, audience/resource binding, scopes and tenant policy.
- [ ] `:allowed_origins` set explicitly (not the localhost default) for browser clients.
- [ ] `:ip` bound to the intended interface.
- [ ] `:expose_internal_errors` left at `false`.
- [ ] `:max_sessions`, `:session_idle_timeout` and `:session_max_lifetime` configured.
- [ ] Rate limiting in front of the transport.
- [ ] Tokens never forwarded to upstream APIs (use a separate upstream token).

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/urth-inc/urchin/security/advisories/new)
for this repository, or contact the maintainers at Urth Inc. We aim to acknowledge reports
promptly and will coordinate a fix and disclosure timeline with you.
