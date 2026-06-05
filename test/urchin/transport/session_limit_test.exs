defmodule Urchin.Transport.SessionLimitTest do
  # async: false — these reason about the global session limiter's count.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Urchin.Session
  alias Urchin.Session.Limiter
  alias Urchin.Transport.StreamableHTTP
  alias Urchin.Test.{EchoServer, RaisingInitServer, SignalingServer}

  defp initialize(opts) do
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

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> StreamableHTTP.call(opts)
  end

  # Fill the global limiter so the next reserve is rejected, capping at the current count.
  defp saturate do
    cap = Limiter.count() + 1
    {:ok, ref} = Limiter.reserve(cap)
    on_exit(fn -> Limiter.release(ref) end)
    cap
  end

  test "rejects new sessions with 503 once the cap is reached" do
    cap = saturate()
    conn = initialize(StreamableHTTP.init(server: EchoServer, max_sessions: cap))
    assert conn.status == 503
    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "does not run the server's init/1 when the cap is reached" do
    cap = saturate()
    conn = initialize(StreamableHTTP.init(server: SignalingServer, max_sessions: cap))
    assert conn.status == 503
    refute_received :init_ran
  end

  test "runs the server's init/1 and starts a session on a normal initialize" do
    conn = initialize(StreamableHTTP.init(server: SignalingServer))
    assert conn.status == 200
    assert_received :init_ran
    [sid] = get_resp_header(conn, "mcp-session-id")
    on_exit(fn -> if pid = Session.whereis(sid), do: Session.terminate(pid) end)
  end

  test "releases the reserved slot and returns 500 when the server's init/1 raises" do
    before = Limiter.count()
    conn = initialize(StreamableHTTP.init(server: RaisingInitServer))
    assert conn.status == 500
    refute conn.resp_body =~ "init boom"
    assert Limiter.count() == before
  end

  test "rejects invalid session-limit options at init" do
    for {key, value} <- [
          {:session_idle_timeout, -1},
          {:session_max_lifetime, 0},
          {:max_sessions, "1"}
        ] do
      assert_raise ArgumentError, fn ->
        StreamableHTTP.init([{:server, EchoServer}, {key, value}])
      end
    end
  end
end
