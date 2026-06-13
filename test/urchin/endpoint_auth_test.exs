defmodule Urchin.EndpointAuthTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Urchin.Auth
  alias Urchin.Endpoint
  alias Urchin.Test.EchoServer

  @auth Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          authorizer: Urchin.Test.RejectAuthorizer
        )

  @config Endpoint.init(server: EchoServer, path: "/mcp", auth: @auth)

  test "the runner serves the discovery document at its well-known path" do
    conn = conn(:get, "/.well-known/oauth-protected-resource/mcp") |> Endpoint.call(@config)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.example.com/mcp"
  end

  test "an unauthenticated MCP request is challenged with 401" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> Endpoint.call(@config)

    assert conn.status == 401
    assert [_challenge] = get_resp_header(conn, "www-authenticate")
  end

  test "unrelated paths still 404" do
    conn = conn(:get, "/nope") |> Endpoint.call(@config)
    assert conn.status == 404
  end
end
