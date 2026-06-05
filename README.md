# Urchin

[![Hex.pm](https://img.shields.io/hexpm/v/urchin.svg)](https://hex.pm/packages/urchin)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/urchin)
[![Test](https://github.com/urth-inc/urchin/actions/workflows/test.yml/badge.svg?branch=develop)](https://github.com/urth-inc/urchin/actions/workflows/test.yml)
[![License](https://img.shields.io/hexpm/l/urchin.svg)](https://github.com/urth-inc/urchin/blob/develop/LICENSE)

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) **server** library
for Elixir, implementing the [`2025-11-25`](https://modelcontextprotocol.io/specification/2025-11-25)
specification over the **Streamable HTTP** transport.

- Define servers with a concise DSL or the full `Urchin.Server` behaviour.
- Mount as a `Plug` into Phoenix/Plug pipelines, or run standalone with Bandit.
- Tools, resources, resource templates, prompts, completion and logging.
- Server-initiated requests over SSE: sampling, elicitation and roots.
- Progress notifications, cancellation, pagination and resumable SSE streams.
- Optional OAuth 2.1 authorization: RFC 9728 discovery and pluggable token validation.

> This library implements the server side only. The stdio transport is intentionally
> not supported; only Streamable HTTP is provided.

## Requirements

- Elixir `~> 1.18` (verified on 1.18 and 1.19)
- Erlang/OTP 25+ (verified on OTP 25, 27 and 28)

## Installation

Add `urchin` to your dependencies:

```elixir
def deps do
  [
    # The Hex badge above shows the latest version. Pre-1.0 minor releases may include
    # breaking changes; pin a minor (e.g. {:urchin, "~> 0.2.0"}) if you need stability.
    {:urchin, "~> 0.2"},
    # Required only for the standalone endpoint (Urchin.start_link / Urchin.Endpoint):
    {:bandit, "~> 1.6"}
  ]
end
```

## Quick start

Define a server with the DSL:

```elixir
defmodule Demo.Server do
  use Urchin.Server, name: "demo", version: "1.0.0", instructions: "A demo MCP server."

  tool "echo",
    description: "Echo the message back",
    input_schema: %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string"}},
      "required" => ["message"]
    } do
    {:ok, [Urchin.Content.text(args["message"])]}
  end

  tool "add",
    description: "Add two integers",
    input_schema: %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}},
      "required" => ["a", "b"]
    },
    output_schema: %{"type" => "object", "properties" => %{"sum" => %{"type" => "integer"}}} do
    sum = args["a"] + args["b"]
    {:ok, [Urchin.Content.text(Integer.to_string(sum))], structured_content: %{"sum" => sum}}
  end
end
```

Run it standalone (requires `:bandit`):

```elixir
{:ok, _pid} = Urchin.start_link(Demo.Server, port: 4000, path: "/mcp")
```

or supervise it:

```elixir
children = [{Urchin.Endpoint, server: Demo.Server, port: 4000, path: "/mcp"}]
Supervisor.start_link(children, strategy: :one_for_one)
```

The endpoint now speaks Streamable HTTP at `http://127.0.0.1:4000/mcp`.

Both forms link the endpoint to the calling process. A long-running application keeps it
alive through its supervision tree; in a one-off `mix run` script you must keep the calling
process alive yourself (the examples block on the supervisor — see `examples/calculator.exs`).

## Mounting in Phoenix / Plug

The transport is a plain `Plug`. Mount it before any body parser, since it reads the
raw request body itself:

```elixir
# Phoenix router
forward "/mcp", Urchin.Transport.StreamableHTTP, server: Demo.Server
```

```elixir
# Plug.Router
forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: Demo.Server]
```

## Resources and prompts

```elixir
defmodule Demo.Server do
  use Urchin.Server, name: "demo", version: "1.0.0"

  resource "config://app", name: "app-config", mime_type: "application/json" do
    {:ok, [Urchin.Content.text_resource(ctx.uri, ~s({"ok": true}), mime_type: "application/json")]}
  end

  # RFC 6570 template; ctx.params holds the extracted variables.
  resource_template "files://{path}", name: "files" do
    {:ok, [Urchin.Content.text_resource(ctx.uri, File.read!(ctx.params["path"]))]}
  end

  prompt "greet",
    description: "A greeting prompt",
    arguments: [%{name: "name", required: true}] do
    {:ok, [Urchin.Prompt.user_message(Urchin.Content.text("Hello " <> args["name"]))], "A greeting"}
  end
end
```

Inside a `tool`/`prompt` block, `args` (the decoded arguments) and `ctx`
(an `Urchin.Context`) are bound. Inside a `resource`/`resource_template` block, only
`ctx` is bound; for templates `ctx.uri` and `ctx.params` are set.

## Content helpers

`Urchin.Content` builds the content blocks used in tool results and prompt messages:

```elixir
Urchin.Content.text("hello")
Urchin.Content.image(base64_png, "image/png")
Urchin.Content.audio(base64_wav, "audio/wav")
Urchin.Content.resource_link(%Urchin.Resource{uri: "file://a", name: "a"})
Urchin.Content.embedded(Urchin.Content.text_resource("file://a", "data"))
```

and the resource contents returned from `resources/read`:

```elixir
Urchin.Content.text_resource("file://a", "data", mime_type: "text/plain")
Urchin.Content.blob_resource("file://a", Base.encode64(bytes), mime_type: "application/octet-stream")
```

## Progress, logging and cancellation

Handlers receive an `Urchin.Context` that can stream notifications related to the
in-flight request. Emitting anything before the result automatically upgrades the
HTTP response to an SSE stream.

```elixir
tool "import", description: "Long running import" do
  Urchin.Context.progress(ctx, 25, total: 100, message: "reading")
  Urchin.Context.log(ctx, "info", "import started")

  if Urchin.Context.cancelled?(ctx) do
    {:error, "cancelled"}
  else
    {:ok, [Urchin.Content.text("done")]}
  end
end
```

Progress notifications are only sent when the client supplied a `progressToken`.

## Server-initiated requests (sampling, elicitation, roots)

A handler can call back into the client and await the response. These travel on the
SSE stream of the originating request; the client's reply arrives on a later POST and
is correlated automatically.

```elixir
tool "summarize", description: "Summarize via the client's LLM" do
  {:ok, result} =
    Urchin.Context.create_message(ctx, %{
      messages: [%{role: "user", content: Urchin.Content.text("Summarize: " <> args["text"])}],
      maxTokens: 200
    })

  {:ok, [Urchin.Content.text(result["content"]["text"])]}
end

tool "ask_name", description: "Ask the user for their name" do
  case Urchin.Context.elicit(ctx, %{
         message: "What is your name?",
         requestedSchema: %{
           "type" => "object",
           "properties" => %{"name" => %{"type" => "string"}},
           "required" => ["name"]
         }
       }) do
    {:ok, %{"action" => "accept", "content" => %{"name" => name}}} ->
      {:ok, [Urchin.Content.text("Hello " <> name)]}

    {:ok, _} ->
      {:ok, [Urchin.Content.text("No name provided")]}
  end
end
```

`Urchin.Context.list_roots/2` is also available.

## Authorization (OAuth 2.1)

Authorization is optional and off by default. When enabled, Urchin acts as an OAuth 2.1
[Resource Server](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization):
it validates inbound bearer tokens and advertises its authorization server through
[RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728) Protected Resource Metadata. The
authorization server itself (token/authorization endpoints, PKCE, consent) is external and
out of scope.

Configure it with `Urchin.Auth.new!/1`. The `:token_validator` is the pluggable seam where
you verify the token's signature/expiry/issuer (with your JWT or introspection library of
choice) and return `Urchin.Auth.Claims`:

```elixir
defmodule Demo.Tokens do
  @behaviour Urchin.Auth.TokenValidator

  @impl true
  def validate(token, _auth) do
    case verify_jwt(token) do
      {:ok, payload} -> {:ok, Urchin.Auth.Claims.from_map(payload)}
      :error -> {:error, :invalid_token}
    end
  end
end

auth =
  Urchin.Auth.new!(
    # canonical server URI; also the expected token audience (RFC 8707)
    resource: "https://mcp.example.com/mcp",
    authorization_servers: ["https://auth.example.com"],
    scopes_supported: ["mcp:tools", "files:read", "files:write"],
    token_validator: Demo.Tokens
  )
```

The standalone runner serves the discovery document for you, at
`https://mcp.example.com/.well-known/oauth-protected-resource/mcp`:

```elixir
{:ok, _pid} = Urchin.start_link(Demo.Server, port: 4000, path: "/mcp", auth: auth)
```

When mounting the transport yourself, add `Urchin.Auth.Metadata` (serves discovery at the
host root) and either pass `:auth` to the transport or use `Urchin.Auth.Plug`:

```elixir
# Plug.Router
plug Urchin.Auth.Metadata, auth: auth
forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: Demo.Server, auth: auth]
```

Unauthenticated requests get a `401` with a `WWW-Authenticate: Bearer ..., resource_metadata="..."`
challenge so clients can discover the authorization server; under-scoped tokens get a `403`
`insufficient_scope`. The validated claims are available to handlers as `ctx.auth` for
per-tool decisions:

Declare required scopes on the tool and they are enforced before the handler runs (this
fails closed: a request with no authorization is denied):

```elixir
tool "delete", description: "Delete a file", scopes: ["files:write"] do
  {:ok, [Urchin.Content.text("deleted")]}
end
```

A per-tool scope failure is returned as a JSON-RPC error from `tools/call`
(`invalid_request`, with `data: %{required_scopes: [...]}`); transport-level
authentication and scope failures remain HTTP `401`/`403`.

Or check `ctx.auth` yourself for finer-grained decisions:

```elixir
tool "delete", description: "Delete a file" do
  if Urchin.Auth.Claims.has_scope?(Urchin.Context.auth(ctx), "files:write") do
    {:ok, [Urchin.Content.text("deleted")]}
  else
    {:error, "files:write scope required"}
  end
end
```

See `Urchin.Auth` for the full option list (audience validation, `required_scopes`, extra
metadata fields).

## The behaviour

For stateful servers or full control, implement `Urchin.Server` directly. All callbacks
except `c:Urchin.Server.server_info/0` are optional, and a feature is supported only when
its callbacks exist.

```elixir
defmodule Custom.Server do
  @behaviour Urchin.Server

  @impl true
  def server_info, do: %{name: "custom", version: "1.0.0"}

  @impl true
  def capabilities, do: Urchin.Capabilities.server(%{tools: %{}})

  @impl true
  def init(_arg), do: {:ok, %{started_at: System.system_time()}}

  @impl true
  def list_tools(_cursor, _ctx), do: {:ok, [Urchin.Tool.new(name: "ping")]}

  @impl true
  def call_tool("ping", _args, ctx) do
    {:ok, [Urchin.Content.text("pong; state=#{inspect(Urchin.Context.state(ctx))}")]}
  end
end
```

The DSL and the behaviour may be mixed: declare some features with the DSL and
hand-write the callbacks for others. State returned by `init/1` is available via
`Urchin.Context.state/1`.

## Transport options

Passed to `Urchin.Transport.StreamableHTTP`, `Urchin.Endpoint` or `Urchin.start_link/2`:

| Option | Default | Description |
| --- | --- | --- |
| `:server` | (required) | the `Urchin.Server` module |
| `:init_arg` | `nil` | argument passed to `init/1` once per session |
| `:allowed_origins` | `nil` | `:all`, a list of allowed `Origin`s, or `nil` for localhost only |
| `:require_session` | `true` | reject post-initialize requests without a session id |
| `:enable_get` | `true` | offer the GET SSE stream (else `405`) |
| `:allow_delete` | `true` | allow client session termination via DELETE (else `405`) |
| `:min_log_level` | `"info"` | default minimum log level for new sessions |
| `:request_timeout` | `60_000` | per-request handler timeout (ms) |
| `:validate_protocol_version` | `true` | validate the `MCP-Protocol-Version` header |
| `:expose_internal_errors` | `false` | return raised-exception messages to the client (dev only); exceptions are always logged |
| `:validate_arguments` | `false` | validate `tools/call` arguments against each tool's `input_schema` (see `Urchin.Schema`) |
| `:max_sessions` | `nil` | reject new sessions with `503` past this many, atomically and before the server's `init/1` runs (`nil` = unlimited) |
| `:session_idle_timeout` | `nil` | terminate a session after this many ms without client activity; a session serving a request is not reaped (`nil` = never) |
| `:session_max_lifetime` | `nil` | terminate a session this many ms after creation regardless of activity; set above your longest tool run (`nil` = never) |
| `:auth` | `nil` | an `Urchin.Auth` (or keyword options) to require OAuth 2.1 bearer tokens; `nil` disables authorization |

`Urchin.Endpoint`/`Urchin.start_link/2` additionally accept `:port`, `:ip`, `:scheme` and `:path`.

## Specification coverage

| Area | Methods |
| --- | --- |
| Lifecycle | `initialize`, `notifications/initialized`, version negotiation |
| Tools | `tools/list`, `tools/call`, `notifications/tools/list_changed` |
| Resources | `resources/list`, `resources/templates/list`, `resources/read`, `resources/subscribe`, `resources/unsubscribe`, `notifications/resources/updated`, `notifications/resources/list_changed` |
| Prompts | `prompts/list`, `prompts/get`, `notifications/prompts/list_changed` |
| Completion | `completion/complete` |
| Logging | `logging/setLevel`, `notifications/message` |
| Utilities | `ping`, `notifications/cancelled`, `notifications/progress`, pagination |
| Server → client | `sampling/createMessage`, `elicitation/create`, `roots/list` |
| Authorization | OAuth 2.1 resource server: RFC 9728 metadata discovery, `WWW-Authenticate` challenges, RFC 8707 audience binding (optional) |

The transport implements: a single endpoint serving POST/GET/DELETE, the
JSON-vs-SSE response decision, `202 Accepted` for notifications and responses,
`Origin` validation, `MCP-Session-Id` management, the `MCP-Protocol-Version` header,
SSE priming events, per-stream event ids, and `Last-Event-ID` resumption of the GET
stream.

### Not included

- The stdio transport (out of scope by design).
- The OAuth 2.1 authorization server: Urchin is the resource server only. Token,
  authorization and registration endpoints, PKCE and consent live in an external
  authorization server.
- Task-augmented execution (`tasks/*`) is not yet implemented; servers advertise no
  `tasks` capability.

## Security

When exposing a server beyond localhost, configure `:allowed_origins`, bind to the
intended interface via `:ip`, and require authorization with `:auth` (see
[Authorization](#authorization-oauth-21)). The transport validates the `Origin` header
(DNS-rebinding protection), issues cryptographically random session ids, redacts
unexpected exception and malformed-return messages by default (`:expose_internal_errors`
is `false`), and only issues server-initiated requests for capabilities the client
advertised.

Session lifecycle limits are built in (`:max_sessions`, `:session_idle_timeout`,
`:session_max_lifetime`); configure them for public deployments. Rate limiting is not yet
built in; add it in front of the transport. See [SECURITY.md](SECURITY.md) for the threat
model, a deployment checklist, and how to report vulnerabilities.

## License

MIT
