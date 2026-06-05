# Run with: mix run examples/keycloak/server.exs
#
# A full OAuth 2.1 example backed by a real authorization server (Keycloak). Urchin
# validates Keycloak-issued access tokens via RFC 7662 token introspection, and the
# official MCP Inspector drives the whole flow: discovery -> dynamic client registration
# -> login -> token. See README.md for the one-time Keycloak setup (docker compose up +
# ./setup.sh).

# :httpc (used below for introspection) lives in :inets, which a bare `mix run` script does
# not always place on the code path. Add inets-*/ebin from the Erlang root, then start it.
# The demo talks to Keycloak over plain HTTP; an HTTPS authorization server would also need
# :ssl started the same way. A real application lists these in mix.exs :extra_applications.
to_string(:code.root_dir())
|> Path.join("lib/inets-*/ebin")
|> Path.wildcard()
|> Enum.each(&:code.add_patha(String.to_charlist(&1)))

{:ok, _} = Application.ensure_all_started(:inets)

defmodule Keycloak.Introspection do
  @moduledoc false
  # Answers "is this token genuine?" by calling Keycloak's RFC 7662 introspection endpoint
  # with a confidential client's credentials. Urchin enforces audience (RFC 8707) and
  # scopes around this. DEV-ONLY: the client secret is inlined for the demo.

  @behaviour Urchin.Auth.TokenValidator

  @endpoint "http://localhost:8080/realms/mcp/protocol/openid-connect/token/introspect"
  @client_id "mcp-resource-server"
  # DEV-ONLY: never hardcode a confidential secret. Load it from the environment in a real
  # app (e.g. System.fetch_env!("KEYCLOAK_INTROSPECTION_SECRET")), and use an https:// endpoint
  # so neither this secret nor the user's bearer token is sent in cleartext.
  @client_secret "mcp-resource-server-secret"

  @impl true
  def validate(token, _auth) do
    basic = Base.encode64("#{@client_id}:#{@client_secret}")
    headers = [{~c"authorization", ~c"Basic " ++ String.to_charlist(basic)}]
    body = URI.encode_query(%{"token" => token, "token_type_hint" => "access_token"})

    request =
      {String.to_charlist(@endpoint), headers, ~c"application/x-www-form-urlencoded",
       String.to_charlist(body)}

    case :httpc.request(:post, request, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _, payload}} ->
        case Jason.decode!(payload) do
          %{"active" => true} = claims -> {:ok, Urchin.Auth.Claims.from_map(claims)}
          _ -> {:error, :invalid_token}
        end

      # A non-200 or a transport error is the authorization server's problem, not the
      # client's: surface a 500 rather than a misleading 401.
      {:ok, {{_, status, _}, _, _}} ->
        {:error, :server_error, "Introspection failed (HTTP #{status})"}

      {:error, reason} ->
        {:error, :server_error, "Authorization server unavailable: #{inspect(reason)}"}
    end
  end
end

defmodule Notes do
  use Urchin.Server,
    name: "notes",
    version: "1.0.0",
    instructions: "A note server demonstrating Keycloak-backed OAuth scopes."

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
    {:ok, [Urchin.Content.text("saved: #{args["text"]}")]}
  end
end

auth =
  Urchin.Auth.new!(
    resource: "http://localhost:4000/mcp",
    authorization_servers: ["http://localhost:8080/realms/mcp"],
    scopes_supported: ["notes:read", "notes:write"],
    required_scopes: ["notes:read"],
    token_validator: Keycloak.Introspection
  )

children = [{Urchin.Endpoint, server: Notes, port: 4000, path: "/mcp", auth: auth}]
{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
IO.puts("Notes MCP server listening on http://127.0.0.1:4000/mcp")

# A bare `mix run` (no --no-halt) halts the VM once this script returns, so block here to
# keep the endpoint serving. Monitoring the supervisor rather than sleeping forever lets a
# crash of the tree propagate as a non-zero exit.
ref = Process.monitor(supervisor)

receive do
  {:DOWN, ^ref, :process, ^supervisor, reason} -> exit(reason)
end
