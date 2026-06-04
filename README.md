# Urchin

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) **server** library
for Elixir, implementing the [`2025-11-25`](https://modelcontextprotocol.io/specification/2025-11-25)
specification over the **Streamable HTTP** transport.

- Define servers with a concise DSL or the full `Urchin.Server` behaviour.
- Mount as a `Plug` into Phoenix/Plug pipelines, or run standalone with Bandit.
- Tools, resources, resource templates, prompts, completion and logging.
- Server-initiated requests over SSE: sampling, elicitation and roots.
- Progress notifications, cancellation, pagination and resumable SSE streams.

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
    {:urchin, "~> 0.1"},
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

The transport implements: a single endpoint serving POST/GET/DELETE, the
JSON-vs-SSE response decision, `202 Accepted` for notifications and responses,
`Origin` validation, `MCP-Session-Id` management, the `MCP-Protocol-Version` header,
SSE priming events, per-stream event ids, and `Last-Event-ID` resumption of the GET
stream.

### Not included

- The stdio transport (out of scope by design).
- OAuth 2.1 authorization is left to surrounding middleware; protect the endpoint with
  your own auth plug and set `:allowed_origins` appropriately.
- Task-augmented execution (`tasks/*`) is not yet implemented; servers advertise no
  `tasks` capability.

## Security

When exposing a server beyond localhost, configure `:allowed_origins`, bind to the
intended interface via `:ip`, and place an authentication/authorization plug in front
of the transport. The transport validates the `Origin` header (DNS-rebinding
protection) and issues cryptographically random session ids by default.

## License

MIT
