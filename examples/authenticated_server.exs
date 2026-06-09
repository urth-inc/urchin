# Run with: mix run examples/authenticated_server.exs
#
# This example turns on OAuth 2.1 authorization. The token validator below is a
# DEV-ONLY stub that accepts two hard-coded tokens; a real server would verify a JWT
# signature or call an introspection endpoint instead.
#
# 1. Discover the authorization server (RFC 9728, no token needed):
#
#      curl -s http://127.0.0.1:4000/.well-known/oauth-protected-resource/mcp | jq
#
# 2. A request without a token is challenged with 401 + WWW-Authenticate:
#
#      curl -i -X POST http://127.0.0.1:4000/mcp \
#        -H 'content-type: application/json' \
#        -H 'accept: application/json, text/event-stream' \
#        -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
#             "params":{"protocolVersion":"2025-11-25","capabilities":{},
#                       "clientInfo":{"name":"curl","version":"1"}}}'
#
# 3. Initialize with a bearer token (note the MCP-Session-Id response header):
#
#      curl -i -X POST http://127.0.0.1:4000/mcp \
#        -H 'authorization: Bearer reader-token' \
#        -H 'content-type: application/json' \
#        -H 'accept: application/json, text/event-stream' \
#        -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
#             "params":{"protocolVersion":"2025-11-25","capabilities":{},
#                       "clientInfo":{"name":"curl","version":"1"}}}'
#
# 4. Call the scoped tool. "reader-token" lacks notes:write and gets a 403, while
#    "writer-token" succeeds:
#
#      curl -s -X POST http://127.0.0.1:4000/mcp \
#        -H 'authorization: Bearer writer-token' \
#        -H 'content-type: application/json' \
#        -H 'accept: application/json, text/event-stream' \
#        -H 'mcp-session-id: <id>' -H 'mcp-protocol-version: 2025-11-25' \
#        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
#             "params":{"name":"save_note","arguments":{"text":"hi"}}}'

defmodule Notes do
  use Urchin.Server,
    name: "notes",
    version: "1.0.0",
    instructions: "A note server demonstrating scope-gated tools."

  tool "whoami", description: "Report the authenticated subject and scopes" do
    _ = args

    case Urchin.Context.auth(ctx) do
      %Urchin.Auth.Claims{subject: subject, scopes: scopes} ->
        {:ok, [Urchin.Content.text("#{subject} (#{Enum.join(scopes, ", ")})")]}

      nil ->
        {:ok, [Urchin.Content.text("anonymous")]}
    end
  end

  tool "save_note",
    description: "Save a note (requires the notes:write scope)",
    scopes: ["notes:write"],
    input_schema: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"]
    } do
    # The notes:write scope is enforced declaratively before this runs, so the handler
    # only deals with the happy path.
    {:ok, [Urchin.Content.text("saved: #{args["text"]}")]}
  end
end

defmodule Notes.Authorizer do
  @moduledoc false
  # DEV-ONLY stub. Replace with real JWT verification or RFC 7662 introspection.

  @behaviour Urchin.Auth.Authorizer

  alias Urchin.Auth.Claims

  # Real tokens are audience-bound (RFC 8707); these stubs carry the matching audience so
  # the default :auto audience check passes.
  @aud ["http://localhost:4000/mcp"]
  @tokens %{
    "reader-token" => %Claims{subject: "reader", scopes: ["notes:read"], audience: @aud},
    "writer-token" => %Claims{subject: "writer", scopes: ["notes:read", "notes:write"], audience: @aud}
  }

  @impl true
  def authorize(nil, _auth, _conn), do: {:error, :missing, "Authorization required"}

  def authorize(token, auth, conn) do
    with {:ok, claims} <- Map.fetch(@tokens, token),
         :ok <- ensure_audience(claims, auth.resource),
         :ok <- ensure_scopes(claims, Urchin.Auth.required_scopes(auth, conn)) do
      {:ok, claims}
    else
      :error -> {:error, :invalid_token}
      :invalid_audience -> {:error, :invalid_token, "Token audience is invalid"}
      :insufficient_scope -> {:error, :insufficient_scope, "Insufficient scope"}
    end
  end

  defp ensure_audience(%Claims{audience: audiences}, resource) do
    if resource in audiences, do: :ok, else: :invalid_audience
  end

  defp ensure_scopes(%Claims{} = claims, required) do
    if Claims.has_scopes?(claims, required), do: :ok, else: :insufficient_scope
  end
end

auth =
  Urchin.Auth.new!(
    resource: "http://localhost:4000/mcp",
    # A fake authorization server; localhost issuers are allowed for local development.
    authorization_servers: ["http://localhost:4001"],
    scopes_supported: ["notes:read", "notes:write"],
    required_scopes: ["notes:read"],
    authorizer: Notes.Authorizer
  )

# This is the child spec you drop straight into your own application's supervision
# tree. In a script we own it ourselves, so we start the supervisor and then block.
children = [
  {Urchin.Endpoint, server: Notes, port: 4000, path: "/mcp", auth: auth}
]

{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
IO.puts("Authenticated Notes MCP server listening on http://127.0.0.1:4000/mcp")
IO.puts("Discovery: http://127.0.0.1:4000/.well-known/oauth-protected-resource/mcp")

# Keep this process alive while the endpoint supervisor runs: Supervisor.start_link links
# the tree to the caller, so blocking here is what keeps the server up. If the supervisor
# goes down, exit with its reason and let `mix run` halt the VM.
ref = Process.monitor(supervisor)

receive do
  {:DOWN, ^ref, :process, ^supervisor, reason} -> exit(reason)
end
