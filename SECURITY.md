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
- **Error redaction.** Raised exceptions are logged in full but not surfaced to clients;
  `:expose_internal_errors` (default `false`) must be opted into for development.
- **Capability-gated server-initiated requests.** `sampling/createMessage`,
  `elicitation/create` and `roots/list` are only sent when the client advertised the
  capability.
- **Bounded request bodies** (`@max_body`, ~8 MB) and a per-request handler timeout.

## What you must add before public exposure

Urchin does **not** yet provide these; supply them in your deployment:

1. **TLS.** Terminate HTTPS at a reverse proxy or the endpoint. OAuth requires HTTPS in
   production.
2. **Authorization.** Set `:auth` (or front the transport with `Urchin.Auth.Plug`). An
   unauthenticated server bound to a public interface exposes every tool to anyone.
3. **Rate limiting / concurrency limits.** Per IP, per session, and for `initialize` and
   long-running tools.
4. **Session lifecycle limits.** Idle timeout, max lifetime, and a cap on concurrent
   sessions / in-flight requests. Sessions persist until the client sends `DELETE`, so an
   unbounded public endpoint can be exhausted.
5. **Per-tool authorization.** Read `ctx.auth` (scopes) in handlers, or gate tools you do
   not want every authenticated caller to reach.
6. **Input validation.** `input_schema` is advertised to clients but arguments are passed
   to handlers as-is; validate them in the handler.

## Deployment checklist

- [ ] HTTPS only; redirect URIs are `localhost` or HTTPS.
- [ ] `:auth` configured with a `token_validator` that verifies signature, expiry, issuer,
      and audience (or relies on the built-in `:auto` audience check).
- [ ] `:allowed_origins` set explicitly (not the localhost default) for browser clients.
- [ ] `:ip` bound to the intended interface.
- [ ] `:expose_internal_errors` left at `false`.
- [ ] Rate limiting and session limits in front of the transport.
- [ ] Tokens never forwarded to upstream APIs (use a separate upstream token).

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/urth-inc/urchin/security/advisories/new)
for this repository, or contact the maintainers at Urth Inc. We aim to acknowledge reports
promptly and will coordinate a fix and disclosure timeline with you.
