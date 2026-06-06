defmodule Urchin.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Urchin.Transport.StreamableHTTP
  alias Urchin.Test.EchoServer

  @opts StreamableHTTP.init(server: EchoServer)

  defp post(body, headers \\ [], opts \\ @opts) do
    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_headers(headers)
    |> StreamableHTTP.call(opts)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  # The registry clears a terminated session asynchronously; poll until it is gone.
  defp wait_for_termination(session_id, retries \\ 50)

  defp wait_for_termination(_session_id, 0), do: :timeout

  defp wait_for_termination(session_id, retries) do
    case Urchin.Session.whereis(session_id) do
      nil ->
        :ok

      _pid ->
        Process.sleep(10)
        wait_for_termination(session_id, retries - 1)
    end
  end

  defp init_session do
    conn =
      post(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "c", "version" => "1"}
        }
      })

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")

    # Complete the handshake so subsequent operation requests pass the lifecycle gate.
    ack = call_with_session(%{jsonrpc: "2.0", method: "notifications/initialized"}, session_id)
    assert ack.status == 202

    {session_id, Jason.decode!(conn.resp_body)}
  end

  defp call_with_session(body, session_id, extra \\ []) do
    post(body, [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"} | extra])
  end

  describe "initialize" do
    test "returns 200 with a session id and the result" do
      {session_id, body} = init_session()
      assert is_binary(session_id)
      assert body["result"]["protocolVersion"] == "2025-11-25"
      assert body["result"]["serverInfo"]["name"] == "echo-server"
    end
  end

  describe "notifications and responses" do
    test "initialized notification yields 202 with no body" do
      {session_id, _} = init_session()
      conn = call_with_session(%{jsonrpc: "2.0", method: "notifications/initialized"}, session_id)
      assert conn.status == 202
      assert conn.resp_body == ""
    end
  end

  describe "requests answered as JSON" do
    test "tools/list" do
      {session_id, _} = init_session()
      conn = call_with_session(%{jsonrpc: "2.0", id: 2, method: "tools/list"}, session_id)
      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["result"]["tools"])
    end

    test "tools/call echo" do
      {session_id, _} = init_session()

      conn =
        call_with_session(
          %{
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: %{name: "echo", arguments: %{message: "hi"}}
          },
          session_id
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["content"] == [%{"type" => "text", "text" => "hi"}]
    end

    test "ping" do
      {session_id, _} = init_session()
      conn = call_with_session(%{jsonrpc: "2.0", id: 9, method: "ping"}, session_id)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"] == %{}
    end

    test "unknown method returns -32601" do
      {session_id, _} = init_session()
      conn = call_with_session(%{jsonrpc: "2.0", id: 10, method: "no/such"}, session_id)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_601
    end
  end

  describe "requests answered as SSE" do
    test "a tool emitting progress streams an SSE response" do
      {session_id, _} = init_session()

      conn =
        call_with_session(
          %{
            jsonrpc: "2.0",
            id: 4,
            method: "tools/call",
            params: %{
              name: "progressive",
              arguments: %{},
              _meta: %{progressToken: "tok-1"}
            }
          },
          session_id
        )

      assert conn.status == 200
      assert ["text/event-stream"] = get_resp_header(conn, "content-type")

      body = conn.resp_body
      # Priming event first, then a progress notification, then the final response.
      assert body =~ ~r/id: p\d+:0/
      assert body =~ "notifications/progress"
      assert body =~ ~s("progressToken":"tok-1")
      assert body =~ ~s("id":4)
      assert body =~ ~s("text":"done")
    end
  end

  describe "keep-alive process reuse" do
    test "no per-request messages linger in the owner mailbox across requests" do
      {session_id, _} = init_session()

      # An SSE request (progressive) leaves a task DOWN behind; a JSON request follows.
      _ =
        call_with_session(
          %{
            jsonrpc: "2.0",
            id: 100,
            method: "tools/call",
            params: %{name: "progressive", arguments: %{}, _meta: %{progressToken: "p"}}
          },
          session_id
        )

      conn =
        call_with_session(
          %{
            jsonrpc: "2.0",
            id: 101,
            method: "tools/call",
            params: %{name: "echo", arguments: %{message: "x"}}
          },
          session_id
        )

      assert conn.status == 200
      # The owner process (this test) must not accumulate stale request messages.
      refute_received {:DOWN, _ref, :process, _pid, _reason}
      refute_received {:mcp_out, _}
      refute_received {:mcp_result, _}
    end
  end

  describe "session validation" do
    test "missing session id on a non-initialize request is 400" do
      conn = post(%{jsonrpc: "2.0", id: 2, method: "tools/list"})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_600
    end

    test "unknown session id is 404" do
      conn = call_with_session(%{jsonrpc: "2.0", id: 2, method: "tools/list"}, "does-not-exist")
      assert conn.status == 404
    end

    test "unsupported protocol version is 400" do
      {session_id, _} = init_session()

      conn =
        post(%{jsonrpc: "2.0", id: 2, method: "tools/list"}, [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "1999-01-01"}
        ])

      assert conn.status == 400
    end
  end

  describe "origin validation" do
    test "a disallowed origin is rejected with 403" do
      conn =
        post(
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}
          },
          [{"origin", "https://evil.example.com"}]
        )

      assert conn.status == 403
    end

    test "a localhost origin is allowed" do
      conn =
        post(
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "c", "version" => "1"}
            }
          },
          [{"origin", "http://localhost:3000"}]
        )

      assert conn.status == 200
    end
  end

  describe "GET and DELETE" do
    test "GET is 405 when disabled" do
      opts = StreamableHTTP.init(server: EchoServer, enable_get: false)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> StreamableHTTP.call(opts)

      assert conn.status == 405
    end

    test "DELETE terminates the session with 204" do
      {session_id, _} = init_session()

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTP.call(@opts)

      assert conn.status == 204
      assert wait_for_termination(session_id) == :ok
    end

    test "DELETE is 405 when disabled" do
      opts = StreamableHTTP.init(server: EchoServer, allow_delete: false)
      {session_id, _} = init_session()

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTP.call(opts)

      assert conn.status == 405
    end
  end

  describe "invalid payloads" do
    test "malformed JSON is a parse error" do
      conn =
        conn(:post, "/", "{not json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_700
    end

    test "a non-JSON Content-Type is rejected with 415" do
      conn =
        conn(:post, "/", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> StreamableHTTP.call(@opts)

      assert conn.status == 415
    end

    test "Content-Type must be exactly the application/json media type" do
      body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"})

      status = fn content_type ->
        conn(:post, "/", body)
        |> put_req_header("content-type", content_type)
        |> put_req_header("accept", "application/json, text/event-stream")
        |> StreamableHTTP.call(@opts)
        |> Map.fetch!(:status)
      end

      # Parameters such as charset are allowed.
      refute status.("application/json; charset=utf-8") == 415
      # Look-alikes are rejected.
      assert status.("application/json-bogus") == 415
      assert status.("text/plain; application/json") == 415
      assert status.("x-application/json") == 415
    end
  end

  describe "initialized lifecycle gate" do
    test "gates operation requests until notifications/initialized" do
      init_conn =
        post(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "c", "version" => "1"}
          }
        })

      assert init_conn.status == 200
      [session_id] = get_resp_header(init_conn, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      # Before notifications/initialized: rejected as invalid_request.
      before = post(%{jsonrpc: "2.0", id: 2, method: "tools/list"}, headers)
      assert before.status == 200
      assert Jason.decode!(before.resp_body)["error"]["code"] == -32_600

      # Acknowledge initialization.
      ack = post(%{jsonrpc: "2.0", method: "notifications/initialized"}, headers)
      assert ack.status == 202

      # After: allowed.
      after_conn = post(%{jsonrpc: "2.0", id: 3, method: "tools/list"}, headers)
      assert after_conn.status == 200
      assert is_list(Jason.decode!(after_conn.resp_body)["result"]["tools"])
    end
  end

  describe "sse_buffer_limit option" do
    test "validates and defaults" do
      assert %{sse_buffer_limit: nil} = StreamableHTTP.init(server: EchoServer)
      assert %{sse_buffer_limit: 5} = StreamableHTTP.init(server: EchoServer, sse_buffer_limit: 5)

      assert_raise ArgumentError, fn ->
        StreamableHTTP.init(server: EchoServer, sse_buffer_limit: 0)
      end

      assert_raise ArgumentError, fn ->
        StreamableHTTP.init(server: EchoServer, sse_buffer_limit: -1)
      end
    end

    test "is forwarded to the session created by the transport" do
      opts = StreamableHTTP.init(server: EchoServer, sse_buffer_limit: 1)

      conn =
        post(
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "c", "version" => "1"}
            }
          },
          [],
          opts
        )

      assert conn.status == 200
      [session_id] = get_resp_header(conn, "mcp-session-id")
      pid = Urchin.Session.whereis(session_id)

      Urchin.Session.notify(pid, "notifications/message", %{"n" => 1})
      Urchin.Session.notify(pid, "notifications/message", %{"n" => 2})

      # With the buffer capped at 1, only the most recent event is available to replay.
      {:ok, "g0", replay} = Urchin.Session.register_general_stream(pid, self(), {"g0", 0})
      assert length(replay) == 1

      Urchin.Session.terminate(pid)
    end
  end

  describe "tool errors over the transport" do
    test "a handler {:error, message} becomes an isError result" do
      {session_id, _} = init_session()

      conn =
        call_with_session(
          %{
            jsonrpc: "2.0",
            id: 20,
            method: "tools/call",
            params: %{name: "failing", arguments: %{}}
          },
          session_id
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["isError"] == true
      assert body["result"]["content"] == [%{"type" => "text", "text" => "tool said no"}]
    end
  end

  describe "logging/setLevel over the transport" do
    test "updates the session min_log_level" do
      {session_id, _} = init_session()
      pid = Urchin.Session.whereis(session_id)

      conn =
        call_with_session(
          %{jsonrpc: "2.0", id: 21, method: "logging/setLevel", params: %{level: "error"}},
          session_id
        )

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"] == %{}
      assert Urchin.Session.snapshot(pid).min_log_level == "error"
    end
  end

  describe "client notifications before initialized" do
    test "client notifications are accepted with 202 before initialized" do
      init =
        post(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "c", "version" => "1"}
          }
        })

      [session_id] = get_resp_header(init, "mcp-session-id")
      headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", "2025-11-25"}]

      cancelled =
        post(
          %{jsonrpc: "2.0", method: "notifications/cancelled", params: %{requestId: "x"}},
          headers
        )

      assert cancelled.status == 202
    end
  end
end
