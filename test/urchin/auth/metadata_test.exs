defmodule Urchin.Auth.MetadataTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Urchin.Auth
  alias Urchin.Auth.Metadata

  @auth Auth.new!(
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"],
          scopes_supported: ["files:read"],
          token_validator: Urchin.Test.RejectValidator
        )

  @config Metadata.init(auth: @auth)

  defp request(method, path) do
    conn(method, path) |> Metadata.call(@config)
  end

  test "serves the metadata document at the path-aware well-known URI" do
    conn = request(:get, "/.well-known/oauth-protected-resource/mcp")
    assert conn.halted
    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    body = Jason.decode!(conn.resp_body)
    assert body["resource"] == "https://mcp.example.com/mcp"
    assert body["authorization_servers"] == ["https://auth.example.com"]
    assert body["bearer_methods_supported"] == ["header"]
    assert body["scopes_supported"] == ["files:read"]
  end

  test "also serves the document at the bare root well-known URI" do
    conn = request(:get, "/.well-known/oauth-protected-resource")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.example.com/mcp"
  end

  test "responds to the metadata document with permissive CORS" do
    conn = request(:get, "/.well-known/oauth-protected-resource/mcp")
    assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
  end

  test "answers an OPTIONS preflight with 204 and CORS" do
    conn = request(:options, "/.well-known/oauth-protected-resource/mcp")
    assert conn.status == 204
    assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
  end

  test "rejects non-GET methods on the metadata endpoint with 405" do
    conn = request(:post, "/.well-known/oauth-protected-resource/mcp")
    assert conn.status == 405
    assert ["GET, OPTIONS"] = get_resp_header(conn, "allow")
    assert Jason.decode!(conn.resp_body)["error"] == "method_not_allowed"
  end

  test "passes non-metadata requests through untouched" do
    conn = request(:get, "/mcp")
    refute conn.halted
    assert conn.status == nil
  end
end
