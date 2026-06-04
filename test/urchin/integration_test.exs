defmodule Urchin.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Urchin.Test.{EchoServer, SSEClient}

  setup do
    port = SSEClient.free_port()
    {:ok, pid} = Urchin.Endpoint.start_link(server: EchoServer, port: port, path: "/mcp")

    on_exit(fn ->
      try do
        Supervisor.stop(pid, :normal, 2_000)
      catch
        _, _ -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end)

    %{port: port}
  end

  defp json_headers do
    [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
  end

  defp session_headers(session_id) do
    json_headers() ++
      [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]
  end

  defp initialize(port) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "c", "version" => "1"}
        }
      })

    {200, headers, resp} = SSEClient.request(port, "POST", "/mcp", json_headers(), body)
    session_id = Enum.find_value(headers, fn {k, v} -> if k == "mcp-session-id", do: v end)
    {session_id, Jason.decode!(resp)}
  end

  test "JSON round trip over a real Bandit server", %{port: port} do
    {session_id, init} = initialize(port)
    assert is_binary(session_id)
    assert init["result"]["serverInfo"]["name"] == "echo-server"

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "echo", arguments: %{message: "hello"}}
      })

    {200, _h, resp} = SSEClient.request(port, "POST", "/mcp", session_headers(session_id), body)
    assert Jason.decode!(resp)["result"]["content"] == [%{"type" => "text", "text" => "hello"}]
  end

  test "GET stream delivers the priming event and server notifications", %{port: port} do
    {session_id, _} = initialize(port)

    {:ok, socket} =
      SSEClient.open(
        port,
        "GET",
        "/mcp",
        [
          {"accept", "text/event-stream"},
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "2025-11-25"}
        ],
        nil
      )

    assert {:ok, buffer} = SSEClient.recv_until(socket, "id: g0:0")

    session_pid = Urchin.Session.whereis(session_id)
    Urchin.Session.notify(session_pid, "notifications/message", %{level: "info", data: "ping"})

    assert {:ok, buffer} = SSEClient.recv_until(socket, "notifications/message", buffer)
    assert buffer =~ ~s("data":"ping")

    # A broadcast reaches the same connected stream.
    assert Urchin.broadcast("notifications/tools/list_changed") >= 1
    assert {:ok, buffer} = SSEClient.recv_until(socket, "tools/list_changed", buffer)
    assert buffer =~ "notifications/tools/list_changed"

    SSEClient.close(socket)
  end

  test "server-initiated elicitation round trip during a tool call", %{port: port} do
    {session_id, _} = initialize(port)

    call_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 5,
        method: "tools/call",
        params: %{name: "ask", arguments: %{}}
      })

    {:ok, socket} = SSEClient.open(port, "POST", "/mcp", session_headers(session_id), call_body)

    # The tool issues elicitation/create on the SSE stream and blocks for the reply.
    assert {:ok, buffer} = SSEClient.recv_until(socket, "elicitation/create")
    assert [_, outbound_id] = Regex.run(~r/"id":"(srv-\d+)"/, buffer)

    # Respond on a separate connection; the session correlates it to the waiting tool.
    reply =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: outbound_id,
        result: %{action: "accept", content: %{name: "Sam"}}
      })

    {202, _h, _b} = SSEClient.request(port, "POST", "/mcp", session_headers(session_id), reply)

    # The tool now completes and writes its result on the original SSE stream.
    assert {:ok, buffer} = SSEClient.recv_until(socket, "Hello Sam", buffer)
    assert buffer =~ ~s("id":5)
    SSEClient.close(socket)
  end

  test "notifications/cancelled stops an in-flight tool and returns a cancellation error", %{
    port: port
  } do
    {session_id, _} = initialize(port)

    call_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{name: "ask", arguments: %{}}
      })

    {:ok, socket} = SSEClient.open(port, "POST", "/mcp", session_headers(session_id), call_body)

    # Wait until the tool is blocked awaiting the elicitation response.
    assert {:ok, _buffer} = SSEClient.recv_until(socket, "elicitation/create")

    cancel =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: %{requestId: 7, reason: "user aborted"}
      })

    {202, _h, _b} = SSEClient.request(port, "POST", "/mcp", session_headers(session_id), cancel)

    # The killed handler still yields a JSON-RPC response on the stream (cancelled).
    assert {:ok, buffer} = SSEClient.recv_until(socket, "-32800", "")
    assert buffer =~ ~s("id":7)
    SSEClient.close(socket)
  end

  test "DELETE terminates the session", %{port: port} do
    {session_id, _} = initialize(port)
    assert Urchin.Session.whereis(session_id) != nil

    {204, _h, _b} =
      SSEClient.request(
        port,
        "DELETE",
        "/mcp",
        [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}],
        nil
      )

    assert Urchin.Session.whereis(session_id) == nil
  end
end
