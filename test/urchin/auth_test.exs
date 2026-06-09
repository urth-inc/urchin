defmodule Urchin.AuthTest do
  use ExUnit.Case, async: true

  alias Urchin.Auth
  alias Urchin.Auth.Claims

  @conn %{realm: "alpha"}

  defp ok_validator,
    do: fn _token, _auth, _conn ->
      {:ok, %Claims{subject: "u1", scopes: ["a"], audience: ["https://mcp.example.com/mcp"]}}
    end

  defp build(opts) do
    [
      resource: "https://mcp.example.com/mcp",
      authorization_servers: ["https://auth.example.com"],
      token_validator: ok_validator()
    ]
    |> Keyword.merge(opts)
    |> Auth.new!()
  end

  describe "new!/1 validation" do
    test "requires :resource" do
      assert_raise ArgumentError, ~r/:resource/, fn ->
        Auth.new!(authorization_servers: ["https://a"], token_validator: ok_validator())
      end
    end

    test "rejects a resource with a fragment" do
      assert_raise ArgumentError, ~r/fragment/, fn ->
        build(resource: "https://mcp.example.com/mcp#x")
      end
    end

    test "rejects a non-absolute resource" do
      assert_raise ArgumentError, ~r/absolute/, fn -> build(resource: "mcp.example.com") end
    end

    test "requires at least one authorization server" do
      assert_raise ArgumentError, ~r/at least one/, fn -> build(authorization_servers: []) end
    end

    test "rejects an http issuer by default" do
      assert_raise ArgumentError, ~r/HTTPS/, fn ->
        build(authorization_servers: ["http://auth.example.com"])
      end
    end

    test "allows an http localhost issuer" do
      auth = build(authorization_servers: ["http://localhost:9000"])
      assert auth.authorization_servers == ["http://localhost:9000"]
    end

    test "allows http issuers when explicitly permitted" do
      auth =
        build(
          authorization_servers: ["http://auth.internal"],
          allow_insecure_authorization_servers: true
        )

      assert auth.authorization_servers == ["http://auth.internal"]
    end

    test "requires a usable :token_validator" do
      assert_raise ArgumentError, ~r/token_validator/, fn ->
        Auth.new!(
          resource: "https://m",
          authorization_servers: ["https://a"],
          token_validator: 123
        )
      end
    end

    test "rejects a module that does not implement validate/3" do
      assert_raise ArgumentError, ~r/validate\/3/, fn -> build(token_validator: Enum) end
    end
  end

  describe "coerce!/1" do
    test "passes a struct and nil through" do
      auth = build([])
      assert Auth.coerce!(auth) == auth
      assert Auth.coerce!(nil) == nil
    end

    test "builds from a keyword list" do
      assert %Auth{} =
               Auth.coerce!(
                 resource: "https://mcp.example.com/mcp",
                 authorization_servers: ["https://auth.example.com"],
                 token_validator: ok_validator()
               )
    end

    test "raises a clear ArgumentError on an unexpected value" do
      assert_raise ArgumentError, ~r/:auth must be/, fn -> Auth.coerce!(true) end
    end
  end

  describe "protected resource metadata (RFC 9728)" do
    test "produces a minimal MCP-conformant document" do
      doc = Auth.metadata_document(build([]), @conn)
      assert doc.resource == "https://mcp.example.com/mcp"
      assert doc.authorization_servers == ["https://auth.example.com"]
      assert doc.bearer_methods_supported == ["header"]
      refute Map.has_key?(doc, :scopes_supported)
    end

    test "includes optional fields when configured" do
      doc =
        Auth.metadata_document(
          build(
            scopes_supported: ["files:read", "files:write"],
            resource_name: "Example MCP",
            jwks_uri: "https://mcp.example.com/jwks.json",
            resource_documentation: "https://docs.example.com"
          ),
          @conn
        )

      assert doc.scopes_supported == ["files:read", "files:write"]
      assert doc.resource_name == "Example MCP"
      assert doc.jwks_uri == "https://mcp.example.com/jwks.json"
      assert doc.resource_documentation == "https://docs.example.com"
    end

    test "merges :metadata overrides last" do
      doc =
        Auth.metadata_document(build(metadata: %{dpop_bound_access_tokens_required: true}), @conn)

      assert doc.dpop_bound_access_tokens_required == true
    end

    test "resolves authorization_servers per request" do
      auth =
        build(
          authorization_servers: fn conn ->
            ["https://auth.example.com/realms/#{conn.realm}"]
          end
        )

      doc = Auth.metadata_document(auth, %{realm: "tenant-a"})
      assert doc.authorization_servers == ["https://auth.example.com/realms/tenant-a"]
    end

    test "validates dynamic authorization_servers when resolved" do
      auth = build(authorization_servers: fn _conn -> ["http://auth.example.com"] end)

      assert_raise ArgumentError, ~r/HTTPS/, fn ->
        Auth.metadata_document(auth, @conn)
      end
    end
  end

  describe "discovery URLs and paths" do
    test "resource_metadata_url inserts the well-known prefix ahead of the path" do
      assert Auth.resource_metadata_url(build([]), @conn) ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    end

    test "resource_metadata_url drops a bare root path" do
      assert Auth.resource_metadata_url(build(resource: "https://mcp.example.com/"), @conn) ==
               "https://mcp.example.com/.well-known/oauth-protected-resource"

      assert Auth.resource_metadata_url(build(resource: "https://mcp.example.com"), @conn) ==
               "https://mcp.example.com/.well-known/oauth-protected-resource"
    end

    test "resource_metadata_url preserves a non-default port" do
      assert Auth.resource_metadata_url(
               build(resource: "https://mcp.example.com:8443/mcp"),
               @conn
             ) ==
               "https://mcp.example.com:8443/.well-known/oauth-protected-resource/mcp"
    end

    test "resource_metadata_url brackets an IPv6 host and elides its default port" do
      assert Auth.resource_metadata_url(build(resource: "https://[::1]:8443/mcp"), @conn) ==
               "https://[::1]:8443/.well-known/oauth-protected-resource/mcp"

      assert Auth.resource_metadata_url(build(resource: "https://[2001:db8::1]/mcp"), @conn) ==
               "https://[2001:db8::1]/.well-known/oauth-protected-resource/mcp"
    end

    test "well_known_paths covers the path-aware and root forms" do
      assert Auth.well_known_paths(build([]), @conn) == [
               "/.well-known/oauth-protected-resource/mcp",
               "/.well-known/oauth-protected-resource"
             ]
    end

    test "well_known_paths is a single entry for a root resource" do
      assert Auth.well_known_paths(build(resource: "https://mcp.example.com"), @conn) == [
               "/.well-known/oauth-protected-resource"
             ]
    end
  end

  describe "verify_token/4" do
    test "missing token" do
      assert {:error, :missing, _} = Auth.verify_token(build([]), nil, [], @conn)
      assert {:error, :missing, _} = Auth.verify_token(build([]), "", [], @conn)
    end

    test "valid token returns claims" do
      assert {:ok, %Claims{subject: "u1"}} = Auth.verify_token(build([]), "tok", [], @conn)
    end

    test "a 3-arity function validator receives the auth and conn" do
      auth =
        build(
          token_validator: fn _token, passed_auth, conn ->
            assert passed_auth.resource == "https://mcp.example.com/mcp"
            assert conn.realm == "alpha"
            {:ok, %Claims{subject: "u2", audience: ["https://mcp.example.com/mcp"]}}
          end
        )

      assert {:ok, %Claims{subject: "u2"}} = Auth.verify_token(auth, "tok", [], @conn)
    end

    test "validator rejection maps to invalid_token" do
      auth = build(token_validator: fn _, _, _ -> {:error, :invalid_token} end)
      assert {:error, :invalid_token, _} = Auth.verify_token(auth, "tok", [], @conn)
    end

    test "a bare binary rejection reason is not reflected to the client" do
      auth = build(token_validator: fn _, _, _ -> {:error, "internal: jwks fetch failed"} end)

      assert {:error, :invalid_token, "Invalid access token"} =
               Auth.verify_token(auth, "tok", [], @conn)
    end

    test "an expired token (exp claim in the past) is rejected" do
      past = System.os_time(:second) - 100
      auth = build(token_validator: fn _, _, _ -> {:ok, %Claims{expires_at: past}} end)

      assert {:error, :invalid_token, "Token has expired"} =
               Auth.verify_token(auth, "tok", [], @conn)
    end

    test "a token expiring exactly now is rejected" do
      now = System.os_time(:second)
      auth = build(token_validator: fn _, _, _ -> {:ok, %Claims{expires_at: now}} end)

      assert {:error, :invalid_token, "Token has expired"} =
               Auth.verify_token(auth, "tok", [], @conn)
    end

    test "a wrong audience is rejected" do
      auth =
        build(
          token_validator: fn _, _, _ ->
            {:ok, %Claims{audience: ["https://other.example.com"]}}
          end
        )

      assert {:error, :invalid_token, message} = Auth.verify_token(auth, "tok", [], @conn)
      assert message =~ "audience"
    end

    test "a matching audience passes (exact and prefix)" do
      exact =
        build(
          token_validator: fn _, _, _ ->
            {:ok, %Claims{audience: ["https://mcp.example.com/mcp"]}}
          end
        )

      assert {:ok, _} = Auth.verify_token(exact, "tok", [], @conn)

      origin =
        build(
          token_validator: fn _, _, _ ->
            {:ok, %Claims{audience: ["https://mcp.example.com"]}}
          end
        )

      assert {:ok, _} = Auth.verify_token(origin, "tok", [], @conn)
    end

    test ":auto rejects a token with no audience (fail closed)" do
      auth = build(token_validator: fn _, _, _ -> {:ok, %Claims{subject: "u1"}} end)
      assert {:error, :invalid_token, message} = Auth.verify_token(auth, "tok", [], @conn)
      assert message =~ "audience"
    end

    test ":skip accepts a token with no audience and ignores a wrong one" do
      no_aud =
        build(audience_validation: :skip, token_validator: fn _, _, _ -> {:ok, %Claims{}} end)

      assert {:ok, _} = Auth.verify_token(no_aud, "tok", [], @conn)

      wrong =
        build(
          audience_validation: :skip,
          token_validator: fn _, _, _ ->
            {:ok, %Claims{audience: ["https://other.example.com"]}}
          end
        )

      assert {:ok, _} = Auth.verify_token(wrong, "tok", [], @conn)
    end

    test "missing required scopes yields insufficient_scope" do
      aud = ["https://mcp.example.com/mcp"]

      auth =
        build(token_validator: fn _, _, _ -> {:ok, %Claims{scopes: ["a"], audience: aud}} end)

      assert {:error, :insufficient_scope, _} =
               Auth.verify_token(auth, "tok", ["a", "b"], @conn)

      assert {:ok, _} = Auth.verify_token(auth, "tok", ["a"], @conn)
    end

    test "a validator that raises produces a server_error" do
      auth = build(token_validator: fn _, _, _ -> raise "boom" end)
      assert {:error, :server_error, _} = Auth.verify_token(auth, "tok", [], @conn)
    end

    test "a plain map result is normalized via Claims.from_map/1" do
      payload = %{"sub" => "u9", "scope" => "x y", "aud" => "https://mcp.example.com/mcp"}
      auth = build(token_validator: fn _, _, _ -> {:ok, payload} end)

      assert {:ok, %Claims{subject: "u9", scopes: ["x", "y"]}} =
               Auth.verify_token(auth, "tok", [], @conn)
    end

    test "a {:error, kind, message} tuple passes through" do
      auth = build(token_validator: fn _, _, _ -> {:error, :invalid_request, "bad"} end)
      assert {:error, :invalid_request, "bad"} = Auth.verify_token(auth, "tok", [], @conn)
    end
  end

  describe "challenge/5" do
    setup do
      %{auth: build([])}
    end

    test "missing -> 401 with resource_metadata and no error param", %{auth: auth} do
      {status, header, body} = Auth.challenge(auth, :missing, "Authorization required", [], @conn)
      assert status == 401

      assert header =~
               ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

      refute header =~ "error="
      assert body.error == "invalid_token"
    end

    test "missing with required scopes adds a scope hint", %{auth: auth} do
      {401, header, _} =
        Auth.challenge(auth, :missing, "msg", ["files:read", "files:write"], @conn)

      assert header =~ ~s(scope="files:read files:write")
    end

    test "invalid_token -> 401 with error and resource_metadata", %{auth: auth} do
      {status, header, body} =
        Auth.challenge(auth, :invalid_token, "Token has expired", [], @conn)

      assert status == 401
      assert header =~ ~s(error="invalid_token")
      assert header =~ ~s(error_description="Token has expired")
      assert header =~ "resource_metadata="
      assert body.error == "invalid_token"
    end

    test "insufficient_scope -> 403 with scope and error", %{auth: auth} do
      {status, header, body} =
        Auth.challenge(auth, :insufficient_scope, "need more", ["a", "b"], @conn)

      assert status == 403
      assert header =~ ~s(error="insufficient_scope")
      assert header =~ ~s(scope="a b")
      assert header =~ "resource_metadata="
      assert body.error == "insufficient_scope"
    end

    test "server_error -> 500 with no challenge", %{auth: auth} do
      assert {500, nil, %{error: "server_error"}} =
               Auth.challenge(auth, :server_error, "boom", [], @conn)
    end

    test "escapes quotes in the error description", %{auth: auth} do
      {401, header, _} = Auth.challenge(auth, :invalid_token, ~s(a"b), [], @conn)
      assert header =~ ~s(error_description="a\\"b")
    end

    test "strips CR/LF from the error description so the header stays well-formed", %{auth: auth} do
      {401, header, _} =
        Auth.challenge(auth, :invalid_token, "line1\r\nInjected: header", [], @conn)

      refute header =~ "\r"
      refute header =~ "\n"
    end

    test "insufficient_scope falls back to scopes_supported when no scopes were resolved" do
      auth = build(scopes_supported: ["files:read", "files:write"])
      {403, header, _} = Auth.challenge(auth, :insufficient_scope, "need more", [], @conn)
      assert header =~ ~s(scope="files:read files:write")
    end
  end

  describe "Urchin.Auth.Claims" do
    test "from_map normalizes the standard OAuth/JWT field names" do
      claims =
        Claims.from_map(%{
          "sub" => "user-1",
          "client_id" => "client-1",
          "exp" => 1_900_000_000,
          "aud" => "https://mcp.example.com/mcp",
          "scope" => "files:read files:write"
        })

      assert claims.subject == "user-1"
      assert claims.client_id == "client-1"
      assert claims.expires_at == 1_900_000_000
      assert claims.audience == ["https://mcp.example.com/mcp"]
      assert claims.scopes == ["files:read", "files:write"]
      assert claims.claims["sub"] == "user-1"
    end

    test "from_map merges scope, scp and scopes; aud as list" do
      claims =
        Claims.from_map(%{"scope" => "a", "scp" => ["b"], "scopes" => ["c"], "aud" => ["x", "y"]})

      assert claims.scopes == ["a", "b", "c"]
      assert claims.audience == ["x", "y"]
    end

    test "from_map falls back to azp for client_id" do
      assert Claims.from_map(%{"azp" => "cli"}).client_id == "cli"
    end

    test "has_scope?/has_scopes?" do
      claims = %Claims{scopes: ["a", "b"]}
      assert Claims.has_scope?(claims, "a")
      refute Claims.has_scope?(claims, "z")
      refute Claims.has_scope?(nil, "a")
      assert Claims.has_scopes?(claims, ["a", "b"])
      refute Claims.has_scopes?(claims, ["a", "z"])
      assert Claims.has_scopes?(claims, [])
    end
  end
end
