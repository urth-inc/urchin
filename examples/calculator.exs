# Run with: mix run --no-halt examples/calculator.exs
#
# Then, from another shell, initialize a session:
#
#   curl -i -X POST http://127.0.0.1:4000/mcp \
#     -H 'content-type: application/json' \
#     -H 'accept: application/json, text/event-stream' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
#          "params":{"protocolVersion":"2025-11-25","capabilities":{},
#                    "clientInfo":{"name":"curl","version":"1"}}}'
#
# Take the Mcp-Session-Id response header and call a tool:
#
#   curl -s -X POST http://127.0.0.1:4000/mcp \
#     -H 'content-type: application/json' \
#     -H 'accept: application/json, text/event-stream' \
#     -H 'mcp-session-id: <id>' -H 'mcp-protocol-version: 2025-11-25' \
#     -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
#          "params":{"name":"add","arguments":{"a":2,"b":3}}}'

defmodule Calculator do
  use Urchin.Server,
    name: "calculator",
    version: "1.0.0",
    instructions: "A tiny calculator exposed over MCP."

  @number_schema %{
    "type" => "object",
    "properties" => %{"a" => %{"type" => "number"}, "b" => %{"type" => "number"}},
    "required" => ["a", "b"]
  }

  tool "add", description: "Add two numbers", input_schema: @number_schema do
    sum = args["a"] + args["b"]
    {:ok, [Urchin.Content.text("#{sum}")], structured_content: %{"result" => sum}}
  end

  tool "multiply", description: "Multiply two numbers", input_schema: @number_schema do
    product = args["a"] * args["b"]
    {:ok, [Urchin.Content.text("#{product}")], structured_content: %{"result" => product}}
  end

  resource "calc://constants/pi", name: "pi", mime_type: "text/plain" do
    {:ok, [Urchin.Content.text_resource(ctx.uri, "3.141592653589793")]}
  end
end

{:ok, _pid} = Urchin.start_link(Calculator, port: 4000, path: "/mcp")
IO.puts("Calculator MCP server listening on http://127.0.0.1:4000/mcp")
