defmodule Urchin.Auth.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Urchin.Auth
  alias Urchin.Auth.Claims
  alias Urchin.Auth.Plug, as: AuthPlug

  @auth Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          scopes_supported: ["files:read", "files:write"],
          required_scopes: ["files:read"],
          authorizer: Urchin.Test.ScopeAuthorizer
        )

  @config AuthPlug.init(auth: @auth)

  defp run(token) do
    conn = conn(:post, "/mcp", "")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    AuthPlug.call(conn, @config)
  end

  test "passes a valid token through and stores the claims" do
    conn = run("good")
    refute conn.halted
    assert %Claims{subject: "alice"} = AuthPlug.fetch_claims(conn)
  end

  test "passes the request connection to the authorizer" do
    auth =
      Auth.new!(
        resource: "https://mcp.example.com/mcp",
        authorization_servers: ["https://auth.example.com"],
        authorizer: fn _token, _auth, conn ->
          {:ok,
           %Claims{
             subject: conn.request_path,
             audience: ["https://mcp.example.com/mcp"]
           }}
        end
      )

    config = AuthPlug.init(auth: auth)

    conn =
      conn(:post, "/tenant-a/mcp", "")
      |> put_req_header("authorization", "Bearer tenant-token")
      |> AuthPlug.call(config)

    refute conn.halted
    assert %Claims{subject: "/tenant-a/mcp"} = AuthPlug.fetch_claims(conn)
  end

  test "can preserve tenant context from challenge to metadata discovery" do
    auth =
      Auth.new!(
        resource: "https://mcp.example.com/mcp",
        resource_metadata_url: fn conn ->
          realm = URI.decode_query(conn.query_string)["realm"]
          "https://mcp.example.com/.well-known/oauth-protected-resource/mcp?realm=#{realm}"
        end,
        authorization_servers: fn conn ->
          realm = URI.decode_query(conn.query_string)["realm"]
          ["https://auth.example.com/realms/#{realm}"]
        end,
        authorizer: Urchin.Test.RejectAuthorizer
      )

    auth_config = AuthPlug.init(auth: auth)
    metadata_config = Urchin.Auth.Metadata.init(auth: auth)

    challenged =
      conn(:post, "/mcp?realm=tenant-a", "")
      |> AuthPlug.call(auth_config)

    [challenge] = get_resp_header(challenged, "www-authenticate")

    assert challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp?realm=tenant-a")

    discovered =
      conn(:get, "/.well-known/oauth-protected-resource/mcp?realm=tenant-a")
      |> Urchin.Auth.Metadata.call(metadata_config)

    assert Jason.decode!(discovered.resp_body)["authorization_servers"] == [
             "https://auth.example.com/realms/tenant-a"
           ]
  end

  test "missing token halts with a 401 and a discovery challenge" do
    conn = run(nil)
    assert conn.halted
    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")

    assert header =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    refute header =~ "error="
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
  end

  test "an invalid token halts with a 401 invalid_token challenge" do
    conn = run("nope")
    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")
    assert header =~ ~s(error="invalid_token")
    assert header =~ "resource_metadata="
  end

  test "a token with the wrong audience halts with a 401 invalid_token challenge" do
    conn = run("wrong-aud")
    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")
    assert header =~ ~s(error="invalid_token")
    assert header =~ ~s(error_description="Token audience is invalid")
  end

  test "a token lacking required scopes halts with a 403 insufficient_scope" do
    conn = run("low")
    assert conn.status == 403
    [header] = get_resp_header(conn, "www-authenticate")
    assert header =~ ~s(error="insufficient_scope")
    assert header =~ ~s(scope="files:read")
    assert Jason.decode!(conn.resp_body)["error"] == "insufficient_scope"
  end

  test "a non-bearer Authorization scheme is treated as missing" do
    conn =
      conn(:post, "/mcp", "")
      |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> AuthPlug.call(@config)

    assert conn.status == 401
    [header] = get_resp_header(conn, "www-authenticate")
    refute header =~ "error="
  end

  test "server_error halts with a 500 and no discovery challenge" do
    auth =
      Auth.new!(
        resource: "https://mcp.example.com/mcp",
        authorization_servers: ["https://auth.example.com"],
        authorizer: fn _, _, _ -> raise "boom" end
      )

    config = AuthPlug.init(auth: auth)

    log =
      capture_log(fn ->
        conn =
          conn(:post, "/mcp", "")
          |> put_req_header("authorization", "Bearer token")
          |> AuthPlug.call(config)

        send(self(), {:conn, conn})
      end)

    assert log =~ "authorizer raised"
    assert_received {:conn, conn}
    assert conn.status == 500
    assert get_resp_header(conn, "www-authenticate") == []
    assert Jason.decode!(conn.resp_body)["error"] == "server_error"
  end

  test "authenticate/2 with nil passes through untouched" do
    conn = conn(:post, "/mcp", "")
    assert {:ok, ^conn} = AuthPlug.authenticate(conn, nil)
  end

  test "init requires an :auth option" do
    assert_raise ArgumentError, fn -> AuthPlug.init([]) end
  end
end
