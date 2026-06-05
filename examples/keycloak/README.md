# OAuth 2.1 with Keycloak

A complete, runnable OAuth example: an Urchin MCP server acting as an OAuth 2.1
**Resource Server**, validating real access tokens issued by **Keycloak**, driven
end-to-end by the official **MCP Inspector**.

Unlike `examples/authenticated_server.exs` (which stubs token validation with hard-coded
strings), this uses a real authorization server, so an MCP client can complete the full
flow: RFC 9728 discovery → RFC 8414 authorization-server metadata → Dynamic Client
Registration → login → PKCE authorization code → bearer token → tool calls.

## Demo

[Watch the demo](./auth-demo.mp4) — the MCP Inspector logging in through Keycloak and
calling the scope-gated tools. (GitHub shows a player when you open the file. To embed an
inline player on this page, upload `auth-demo.mp4` through the PR/issue web UI and paste the
`user-attachments` URL GitHub generates.)

## Requirements

- Docker (for Keycloak)
- Elixir, run from the repo root so `mix` resolves Urchin and Bandit
- Node.js, for `npx @modelcontextprotocol/inspector`
- `curl` and `python3` (used by `setup.sh` and the curl examples below)

## 1. Start Keycloak

```sh
cd examples/keycloak
docker compose up -d
./setup.sh
```

`setup.sh` waits for Keycloak to come up, then creates the `mcp` realm, clients, scopes and
a test user, printing `Realm 'mcp' ready. Login: alice / password`. Run it once against a
fresh Keycloak; to start over, `docker compose down && docker compose up -d` (the database
is in-memory) and re-run it.

## 2. Start the MCP server

From the repository root:

```sh
mix run examples/keycloak/server.exs
```

It listens on `http://127.0.0.1:4000/mcp` and answers unauthenticated requests with `401`
plus a `WWW-Authenticate` header pointing at its Protected Resource Metadata.

## 3. Connect the MCP Inspector

```sh
npx @modelcontextprotocol/inspector
```

In the UI (http://localhost:6274):

1. Transport: **Streamable HTTP**, URL: `http://localhost:4000/mcp`
2. Click **Connect** / **Quick OAuth Flow**. The Inspector discovers Keycloak, registers
   itself via Dynamic Client Registration, and redirects you to the Keycloak login.
3. Log in as **`alice` / `password`** and approve the consent screen.
4. Back in the Inspector, call the tools: `whoami` and `save_note` both work, because the
   Inspector requests both `notes:read` and `notes:write`.

> If a login attempt gets stuck ("Restart login cookie not found"), click **Clear OAuth
> State**, clear cookies for `http://localhost:8080`, and run the flow once cleanly.

## Testing without a browser

Mint a token with the resource-owner password grant (enabled here only for convenience —
see the DEV-ONLY notes) and call the server directly:

```sh
token() {
  curl -s http://localhost:8080/realms/mcp/protocol/openid-connect/token \
    -d grant_type=password -d client_id=mcp-inspector \
    -d username=alice -d password=password -d "scope=openid $1" |
    python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

RO=$(token "notes:read")

# initialize succeeds and returns an Mcp-Session-Id response header
SID=$(curl -s -D - -o /dev/null -X POST http://127.0.0.1:4000/mcp \
  -H "authorization: Bearer $RO" -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}' |
  awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')

# save_note needs notes:write, which this token lacks. The scope gate is a tool-level check,
# so it comes back as a JSON-RPC error inside a 200 response (distinct from the 401 that a
# missing/invalid token, or the request-level required_scopes, would produce):
#   {"error":{"code":-32600,...,"message":"Insufficient scope; requires: notes:write"}}
curl -s -X POST http://127.0.0.1:4000/mcp \
  -H "authorization: Bearer $RO" -H "mcp-session-id: $SID" \
  -H 'mcp-protocol-version: 2025-11-25' -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"save_note","arguments":{"text":"hi"}}}'
```

Use `token "notes:read notes:write"` instead and the same `save_note` call succeeds.

## What this demonstrates

| Concern | How |
| --- | --- |
| Token validation | `Keycloak.Introspection` calls Keycloak's RFC 7662 introspection endpoint (stdlib `:httpc`, no extra dependency); issuer trust is implicit in introspecting against the realm-scoped endpoint. |
| Audience binding (RFC 8707) | An Audience mapper puts `http://localhost:4000/mcp` in the token's `aud`; Urchin's default `audience_validation: :auto` rejects tokens not bound to this resource. |
| Scope enforcement | `required_scopes: ["notes:read"]` gates every request (401 if absent); `save_note` additionally declares `scopes: ["notes:write"]`, enforced as a tool-level JSON-RPC error. |
| Discovery | Urchin serves RFC 9728 Protected Resource Metadata; the Inspector follows it to Keycloak's RFC 8414 metadata. |

## Credentials and endpoints

| | |
| --- | --- |
| Keycloak admin | `admin` / `admin` at http://localhost:8080/admin |
| Realm issuer | `http://localhost:8080/realms/mcp` |
| Test user | `alice` / `password` |
| Inspector client | `mcp-inspector` (public, PKCE) |
| Resource-server client | `mcp-resource-server` / `mcp-resource-server-secret` |

## Cleanup

```sh
docker compose down
```

## DEV-ONLY notes

This setup trades security for a frictionless demo and must not be copied verbatim into
production:

- Plain HTTP everywhere. Introspection sends the resource-server client secret (Basic auth)
  and the user's bearer token to Keycloak — over HTTP both travel in cleartext. Use HTTPS,
  and pass `:httpc` ssl options with `verify: :verify_peer` and a CA store.
- The client secret is inlined in `server.exs`; load it from the environment instead.
- `Require SSL = None`, an in-memory database, and the anonymous Trusted Hosts
  client-registration policy is removed (so Dynamic Client Registration is open from any
  host). Restrict or disable DCR — or pre-register clients — in production.
- The resource-owner password grant (direct access grant) is enabled on `mcp-inspector` only
  so the curl examples can skip the browser. OAuth 2.1 prohibits it; real clients should use
  the authorization-code + PKCE flow the Inspector demonstrates.
- Never log bearer tokens or the `Authorization` header; consider short-TTL caching of
  introspection results to avoid a network round-trip per request.
