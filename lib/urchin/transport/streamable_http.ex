defmodule Urchin.Transport.StreamableHTTP do
  @moduledoc """
  A `Plug` implementing the MCP Streamable HTTP transport (revision 2025-11-25).

  Mount it at a single endpoint path serving POST, GET and DELETE:

      forward "/mcp", to: Urchin.Transport.StreamableHTTP, init_opts: [server: MyServer]

  or run it standalone via `Urchin.start_link/2` / `Urchin.Endpoint`.

  ## Options

    * `:server` (required) - a module implementing `Urchin.Server`
    * `:init_arg` - argument passed to `c:Urchin.Server.init/1` once per session (default `nil`)
    * `:allowed_origins` - `:all`, a list of allowed `Origin` values, or `nil` to allow
      missing origins plus localhost (default `nil`)
    * `:require_session` - reject post-initialize requests without a session id (default `true`)
    * `:enable_get` - offer the GET SSE stream (default `true`)
    * `:allow_delete` - allow client session termination via DELETE (default `true`)
    * `:min_log_level` - default minimum log level for new sessions (default `"info"`)
    * `:request_timeout` - per-request handler timeout in ms (default `60_000`)
    * `:validate_protocol_version` - validate the `MCP-Protocol-Version` header (default `true`)

  The plug reads the raw request body itself, so mount it before any JSON body parser.
  """

  @behaviour Plug

  import Plug.Conn

  alias Urchin.{Context, Dispatcher, Error, JSONRPC, Protocol, Session, SSE}

  @session_header "mcp-session-id"
  @version_header "mcp-protocol-version"
  @max_body 8_000_000

  @impl true
  def init(opts) do
    server =
      Keyword.get(opts, :server) ||
        raise ArgumentError, "#{inspect(__MODULE__)} requires a :server option"

    %{
      server: server,
      init_arg: Keyword.get(opts, :init_arg),
      allowed_origins: Keyword.get(opts, :allowed_origins),
      require_session: Keyword.get(opts, :require_session, true),
      enable_get: Keyword.get(opts, :enable_get, true),
      allow_delete: Keyword.get(opts, :allow_delete, true),
      min_log_level: Keyword.get(opts, :min_log_level, "info"),
      request_timeout: Keyword.get(opts, :request_timeout, 60_000),
      validate_protocol_version: Keyword.get(opts, :validate_protocol_version, true)
    }
  end

  @impl true
  def call(conn, config) do
    case validate_origin(conn, config) do
      :ok -> route(conn, config)
      :forbidden -> send_error(conn, 403, nil, Error.invalid_request("Origin not allowed"))
    end
  end

  defp route(%{method: "POST"} = conn, config), do: handle_post(conn, config)
  defp route(%{method: "GET"} = conn, config), do: handle_get(conn, config)
  defp route(%{method: "DELETE"} = conn, config), do: handle_delete(conn, config)

  defp route(conn, _config) do
    conn
    |> put_resp_header("allow", "GET, POST, DELETE")
    |> send_error(405, nil, Error.invalid_request("Method not allowed"))
  end

  ## POST

  defp handle_post(conn, config) do
    with :ok <- check_accept_post(conn),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, decoded} <- JSONRPC.decode(body) do
      dispatch_post(conn, config, decoded)
    else
      {:error, %Error{} = error} -> send_error(conn, status_for(error), nil, error)
      :not_acceptable -> send_error(conn, 406, nil, Error.invalid_request("Not Acceptable"))
      {:too_large, conn} -> send_error(conn, 413, nil, Error.invalid_request("Payload too large"))
    end
  end

  # The initialize handshake creates the session and is answered with a single JSON object.
  defp dispatch_post(conn, config, {:request, id, "initialize", params}) do
    ctx = %Context{}

    case Dispatcher.initialize(config.server, params, ctx) do
      {:ok, result, meta} ->
        case init_server_state(config) do
          {:ok, server_state} ->
            {:ok, session_id, _pid} =
              Session.start(
                server: config.server,
                server_state: server_state,
                protocol_version: meta.protocol_version,
                client_info: meta.client_info,
                client_capabilities: meta.client_capabilities,
                min_log_level: config.min_log_level
              )

            conn
            |> put_resp_header(@session_header, session_id)
            |> send_json(200, JSONRPC.result(id, result))

          {:error, reason} ->
            send_error(
              conn,
              500,
              id,
              Error.internal_error("Server init failed: #{inspect(reason)}")
            )
        end

      {:error, error} ->
        send_error(conn, status_for(error), id, error)
    end
  end

  defp dispatch_post(conn, config, decoded) do
    with {:ok, session_pid} <- lookup_session(conn, config),
         :ok <- check_protocol_version(conn, config) do
      route_session_message(conn, config, session_pid, decoded)
    else
      {:error, status, error} -> send_error(conn, status, message_id(decoded), error)
    end
  end

  # Notifications and responses are acknowledged with 202 and routed into the session.
  defp route_session_message(conn, _config, session_pid, {:notification, _m, _p} = msg) do
    Session.handle_client_message(session_pid, msg)
    send_resp(conn, 202, "")
  end

  defp route_session_message(conn, _config, session_pid, {:response, _id, _r} = msg) do
    Session.handle_client_message(session_pid, msg)
    send_resp(conn, 202, "")
  end

  defp route_session_message(conn, _config, session_pid, {:error_response, _id, _e} = msg) do
    Session.handle_client_message(session_pid, msg)
    send_resp(conn, 202, "")
  end

  defp route_session_message(conn, config, session_pid, {:request, id, method, params}) do
    run_request(conn, config, session_pid, id, method, params)
  end

  ## Request execution: JSON or SSE decided by the first message the handler emits.

  defp run_request(conn, config, session_pid, id, method, params) do
    snapshot = Session.snapshot(session_pid)
    owner = self()

    ctx = %Context{
      session: session_pid,
      owner: owner,
      request_id: id,
      progress_token: progress_token(params),
      protocol_version: snapshot.protocol_version,
      client_info: snapshot.client_info,
      client_capabilities: snapshot.client_capabilities,
      state: snapshot.server_state,
      min_log_level: snapshot.min_log_level
    }

    {task_pid, task_ref} =
      spawn_monitor(fn ->
        response =
          case Dispatcher.handle_request(snapshot.server, method, params, ctx) do
            {:ok, result} -> JSONRPC.result(id, result)
            {:error, error} -> JSONRPC.error_response(id, error)
          end

        send(owner, {:mcp_result, response})
      end)

    stream_id = Session.start_request(session_pid, id, task_pid, owner)

    result = await_first(conn, id, stream_id, task_pid, task_ref, config.request_timeout)
    Session.finish_request(session_pid, id)

    # Bandit reuses one process across keep-alive requests, so clear any per-request
    # messages (the task's DOWN, late notifications, a stray cancel) before returning.
    Process.demonitor(task_ref, [:flush])
    drain_request_messages(id)

    result
  end

  defp drain_request_messages(id) do
    receive do
      {:mcp_out, _message} -> drain_request_messages(id)
      {:mcp_result, _response} -> drain_request_messages(id)
    after
      0 -> :ok
    end
  end

  # Wait for the first signal: a direct result -> JSON; any streamed message -> SSE.
  # The handler runs in a monitored task; a :killed DOWN means cancellation/timeout,
  # any other reason means the handler crashed.
  defp await_first(conn, id, stream_id, task_pid, task_ref, timeout) do
    receive do
      {:mcp_result, response} ->
        send_json(conn, 200, response)

      {:mcp_out, message} ->
        conn
        |> begin_sse(stream_id)
        |> sse_loop(id, message, stream_id, 1, task_ref)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        send_json(conn, 200, JSONRPC.error_response(id, down_to_error(reason)))
    after
      timeout ->
        Process.exit(task_pid, :kill)

        send_json(
          conn,
          200,
          JSONRPC.error_response(id, Error.internal_error("Request timed out"))
        )
    end
  end

  # SSE streaming: emit messages until the final response, then terminate the stream.
  defp sse_loop(conn, id, message, stream_id, seq, task_ref) do
    case sse_write(conn, stream_id, seq, message) do
      {:ok, conn} -> sse_recv(conn, id, stream_id, seq + 1, task_ref)
      {:halt, conn} -> conn
    end
  end

  defp sse_recv(conn, id, stream_id, seq, task_ref) do
    receive do
      {:mcp_out, message} ->
        sse_loop(conn, id, message, stream_id, seq, task_ref)

      {:mcp_result, response} ->
        finish_sse(conn, stream_id, seq, response)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        # The handler died after the stream opened; still deliver a JSON-RPC response
        # for the request so the client is not left waiting.
        finish_sse(conn, stream_id, seq, JSONRPC.error_response(id, down_to_error(reason)))
    end
  end

  defp finish_sse(conn, stream_id, seq, response) do
    case sse_write(conn, stream_id, seq, response) do
      {:ok, conn} -> conn
      {:halt, conn} -> conn
    end
  end

  defp down_to_error(:killed), do: cancelled_error()
  defp down_to_error(reason), do: down_error(reason)

  ## GET (server-push SSE stream)

  defp handle_get(conn, %{enable_get: false} = _config) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_error(405, nil, Error.invalid_request("GET stream not supported"))
  end

  defp handle_get(conn, config) do
    with :ok <- check_accept_get(conn),
         {:ok, session_pid} <- lookup_session(conn, config),
         :ok <- check_protocol_version(conn, config) do
      open_general_stream(conn, session_pid)
    else
      :not_acceptable -> send_error(conn, 406, nil, Error.invalid_request("Not Acceptable"))
      {:error, status, error} -> send_error(conn, status, nil, error)
    end
  end

  defp open_general_stream(conn, session_pid) do
    resume_from =
      case get_req_header(conn, "last-event-id") do
        [value | _] -> SSE.parse_event_id(value)
        [] -> nil
      end

    {:ok, stream_id, replay} = Session.register_general_stream(session_pid, self(), resume_from)

    # On resume the client already holds a cursor; re-priming with seq 0 would lower its
    # Last-Event-ID below the resume point, so prime only on a fresh connection.
    conn = if resume_from, do: open_sse(conn), else: begin_sse(conn, stream_id)
    conn = replay_events(conn, replay)
    general_loop(conn)
  end

  defp replay_events(conn, events) do
    Enum.reduce_while(events, conn, fn {event_id, json}, conn ->
      case chunk(conn, SSE.message(event_id, json)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # The GET stream lives until the client disconnects; events arrive as
  # {:mcp_event, id, json} from the session. A periodic keep-alive comment both
  # prevents idle proxies from closing the stream and detects a vanished client
  # (chunk/2 fails once the socket is gone).
  @heartbeat_interval 30_000

  defp general_loop(conn) do
    receive do
      {:mcp_event, event_id, json} ->
        case chunk(conn, SSE.message(event_id, json)) do
          {:ok, conn} -> general_loop(conn)
          {:error, _} -> conn
        end

      # The session has registered a newer GET stream; stop this one.
      :mcp_close ->
        conn
    after
      @heartbeat_interval ->
        case chunk(conn, SSE.comment("keep-alive")) do
          {:ok, conn} -> general_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  ## DELETE (session termination)

  defp handle_delete(conn, %{allow_delete: false}) do
    conn
    |> put_resp_header("allow", "GET, POST")
    |> send_error(405, nil, Error.invalid_request("Session termination not allowed"))
  end

  defp handle_delete(conn, config) do
    case lookup_session(conn, config) do
      {:ok, session_pid} ->
        Session.terminate(session_pid)
        send_resp(conn, 204, "")

      {:error, status, error} ->
        send_error(conn, status, nil, error)
    end
  end

  ## Session + header validation

  defp lookup_session(conn, config) do
    case get_req_header(conn, @session_header) do
      [id | _] ->
        case Session.whereis(id) do
          nil ->
            {:error, 404, Error.invalid_request("Session not found")}

          pid ->
            if Process.alive?(pid),
              do: {:ok, pid},
              else: {:error, 404, Error.invalid_request("Session not found")}
        end

      [] ->
        if config.require_session do
          {:error, 400, Error.invalid_request("Missing #{@session_header} header")}
        else
          {:error, 400, Error.invalid_request("Session required")}
        end
    end
  end

  defp check_protocol_version(_conn, %{validate_protocol_version: false}), do: :ok

  defp check_protocol_version(conn, _config) do
    case get_req_header(conn, @version_header) do
      [] ->
        # Per the transport spec, assume 2025-03-26 when the header is absent.
        :ok

      [version | _] ->
        if Protocol.supported?(version) do
          :ok
        else
          {:error, 400, Error.invalid_request("Unsupported #{@version_header}: #{version}")}
        end
    end
  end

  defp init_server_state(config) do
    if function_exported?(config.server, :init, 1) do
      case config.server.init(config.init_arg) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_init_return, other}}
      end
    else
      {:ok, nil}
    end
  end

  ## Origin / Accept

  defp validate_origin(conn, config) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _] ->
        if origin_allowed?(origin, config.allowed_origins), do: :ok, else: :forbidden
    end
  end

  defp origin_allowed?(_origin, :all), do: true
  defp origin_allowed?(origin, list) when is_list(list), do: origin in list
  defp origin_allowed?(origin, nil), do: localhost_origin?(origin)

  defp localhost_origin?(origin) do
    Regex.match?(~r{^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$}i, origin)
  end

  # POST: the client MUST accept both application/json and text/event-stream, since the
  # server may answer either way.
  defp check_accept_post(conn),
    do: accept_includes(conn, ["application/json", "text/event-stream"], :all)

  # GET: the client MUST accept text/event-stream.
  defp check_accept_get(conn), do: accept_includes(conn, ["text/event-stream"], :any)

  # A missing Accept header or `*/*` passes. Otherwise, in `:all` mode every listed
  # media type must be present; in `:any` mode at least one must be.
  defp accept_includes(conn, acceptable, mode) do
    case get_req_header(conn, "accept") do
      [] ->
        :ok

      values ->
        joined = values |> Enum.join(",") |> String.downcase()
        present = fn type -> String.contains?(joined, type) end

        acceptable_present =
          case mode do
            :all -> Enum.all?(acceptable, present)
            :any -> Enum.any?(acceptable, present)
          end

        if String.contains?(joined, "*/*") or acceptable_present, do: :ok, else: :not_acceptable
    end
  end

  ## SSE helpers

  # Opens the chunked SSE response and emits the priming event (seq 0) so a fresh
  # client can reconnect using it as Last-Event-ID.
  defp begin_sse(conn, stream_id) do
    conn = open_sse(conn)

    case chunk(conn, SSE.priming(SSE.event_id(stream_id, 0))) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # Opens the chunked SSE response without a priming event (used when resuming).
  defp open_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp sse_write(conn, stream_id, seq, message) do
    json = JSONRPC.encode!(message)

    case chunk(conn, SSE.message(SSE.event_id(stream_id, seq), json)) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:halt, conn}
    end
  end

  defp progress_token(params) do
    case params do
      %{"_meta" => %{"progressToken" => token}} -> token
      _ -> nil
    end
  end

  ## Body + responses

  defp read_full_body(conn), do: read_full_body(conn, "")

  defp read_full_body(conn, acc) do
    case read_body(conn, length: 1_000_000) do
      {:ok, body, conn} ->
        {:ok, acc <> body, conn}

      {:more, body, conn} ->
        acc = acc <> body
        if byte_size(acc) > @max_body, do: {:too_large, conn}, else: read_full_body(conn, acc)

      {:error, _reason} ->
        {:error, Error.invalid_request("Could not read request body")}
    end
  end

  defp send_json(conn, status, message) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, JSONRPC.encode!(message))
  end

  defp send_error(conn, status, id, error) do
    send_json(conn, status, JSONRPC.error_response(id, error))
  end

  defp status_for(%Error{code: -32_700}), do: 400
  defp status_for(%Error{code: -32_600}), do: 400
  defp status_for(%Error{code: -32_602}), do: 400
  defp status_for(_), do: 400

  defp message_id({:request, id, _m, _p}), do: id
  defp message_id(_), do: nil

  defp cancelled_error, do: Error.new(-32_800, "Request cancelled")
  defp down_error(reason), do: Error.internal_error("Handler terminated: #{inspect(reason)}")
end
