defmodule Urchin.Transport.StreamableHTTPAuthTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Urchin.Auth
  alias Urchin.Transport.StreamableHTTP
  alias Urchin.Test.EchoServer

  @auth Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          token_validator: Urchin.Test.AliceValidator
        )

  @opts StreamableHTTP.init(server: EchoServer, auth: @auth)

  defp post(body, headers) do
    Enum.reduce(headers, conn(:post, "/", Jason.encode!(body)), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> StreamableHTTP.call(@opts)
  end

  defp initialize(headers) do
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
      headers
    )
  end

  test "an unauthenticated initialize is rejected with 401 and a discovery challenge" do
    conn = initialize([])
    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")

    assert header =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "an invalid token is rejected with 401 invalid_token" do
    conn = initialize([{"authorization", "Bearer wrong"}])
    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")
    assert header =~ ~s(error="invalid_token")
  end

  test "a valid token completes initialize and opens a session" do
    conn = initialize([{"authorization", "Bearer alice-token"}])
    assert conn.status == 200
    assert [_session_id] = get_resp_header(conn, "mcp-session-id")
  end

  test "the validated claims reach handlers as ctx.auth" do
    conn = initialize([{"authorization", "Bearer alice-token"}])
    [session_id] = get_resp_header(conn, "mcp-session-id")

    conn =
      post(
        %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "whoami", arguments: %{}}},
        [
          {"authorization", "Bearer alice-token"},
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "2025-11-25"}
        ]
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["content"] == [%{"type" => "text", "text" => "alice:mcp:tools"}]
  end

  test "every request is authenticated, not just initialize" do
    conn = initialize([{"authorization", "Bearer alice-token"}])
    [session_id] = get_resp_header(conn, "mcp-session-id")

    # A follow-up request without the token is rejected even with a valid session.
    conn =
      post(%{jsonrpc: "2.0", id: 3, method: "tools/list"}, [
        {"mcp-session-id", session_id},
        {"mcp-protocol-version", "2025-11-25"}
      ])

    assert conn.status == 401
  end
end
