defmodule Urchin.Session do
  @moduledoc """
  Per-session state for the Streamable HTTP transport.

  A session is created when a client completes the `initialize` handshake and is
  addressed thereafter by its `MCP-Session-Id`. It tracks:

    * negotiated protocol version, client info and capabilities
    * the requested minimum log level and resource subscriptions
    * the connected GET ("general") SSE stream plus a replay buffer for resumption
    * in-flight POST requests, so `notifications/cancelled` can stop them
    * outbound server-to-client requests, so client responses can be correlated

  Transport (`Plug`) processes and handler tasks talk to this process; it never owns
  an HTTP connection itself.
  """

  # A session that ends (via DELETE, idle, max-lifetime or a crash) must stay ended rather
  # than be resurrected by the supervisor under its old id.
  use GenServer, restart: :temporary

  alias Urchin.{Error, JSONRPC, SSE}

  @registry Urchin.Session.Registry
  @supervisor Urchin.Session.Supervisor
  @default_buffer_limit 100

  ## Lifecycle

  @doc """
  Starts a session under the session supervisor and returns its id and pid.

  Returns `{:error, :max_sessions}` when `:max_sessions` is set and the registry already
  holds that many sessions.
  """
  @spec start(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start(opts) do
    {max_sessions, opts} = Keyword.pop(opts, :max_sessions)

    if max_sessions && Registry.count(@registry) >= max_sessions do
      {:error, :max_sessions}
    else
      id = Keyword.get(opts, :id) || generate_id()
      opts = Keyword.put(opts, :id, id)

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
        {:ok, pid} -> {:ok, id, pid}
        {:error, {:already_started, pid}} -> {:ok, id, pid}
        other -> other
      end
    end
  end

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Looks up a live session pid by id."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Terminates a session process."
  @spec terminate(pid()) :: :ok
  def terminate(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(@supervisor, pid)
    :ok
  end

  defp via(id), do: {:via, Registry, {@registry, id}}

  @doc "Generates a cryptographically random, visible-ASCII session id."
  @spec generate_id() :: String.t()
  def generate_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  ## Client API

  @doc "Returns a snapshot of the data needed to build a request context."
  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc """
  Registers an in-flight POST request so it can be cancelled, returning a unique
  per-session SSE stream id for that request's response stream.
  """
  @spec start_request(pid(), JSONRPC.id(), pid(), pid()) :: String.t()
  def start_request(pid, request_id, task_pid, owner_pid) do
    GenServer.call(pid, {:start_request, request_id, task_pid, owner_pid})
  end

  @doc "Removes a completed in-flight POST request."
  @spec finish_request(pid(), JSONRPC.id()) :: :ok
  def finish_request(pid, request_id), do: GenServer.cast(pid, {:finish_request, request_id})

  @doc "Returns true if the given in-flight request has been cancelled."
  @spec cancelled?(pid(), JSONRPC.id()) :: boolean()
  def cancelled?(pid, request_id), do: GenServer.call(pid, {:cancelled?, request_id})

  @doc "Allocates an outbound request id and records the caller awaiting the response."
  @spec register_outbound(pid(), pid()) :: String.t()
  def register_outbound(pid, caller), do: GenServer.call(pid, {:register_outbound, caller})

  @doc "Drops a pending outbound request (e.g. on timeout)."
  @spec cancel_outbound(pid(), String.t()) :: :ok
  def cancel_outbound(pid, id), do: GenServer.cast(pid, {:cancel_outbound, id})

  @doc """
  Handles a client-originated notification or response delivered over POST.

  Notifications (`notifications/cancelled`, `notifications/initialized`, ...) update
  session state; responses are correlated to a pending outbound request.
  """
  @spec handle_client_message(pid(), Urchin.JSONRPC.decoded()) :: :ok
  def handle_client_message(pid, message), do: GenServer.cast(pid, {:client_message, message})

  @doc "Sets the minimum log level the client wishes to receive."
  @spec set_log_level(pid(), String.t()) :: :ok
  def set_log_level(pid, level), do: GenServer.cast(pid, {:set_log_level, level})

  @doc "Registers (or replaces) the GET general stream, returning events to replay."
  @spec register_general_stream(pid(), pid(), {String.t(), non_neg_integer()} | nil) ::
          {:ok, String.t(), [{String.t(), iodata()}]}
  def register_general_stream(pid, owner, resume_from \\ nil) do
    GenServer.call(pid, {:register_general_stream, owner, resume_from})
  end

  @doc "Sends an unsolicited notification to the client on the general stream."
  @spec notify(pid(), String.t(), map() | nil) :: :ok
  def notify(pid, method, params \\ nil) do
    GenServer.cast(pid, {:notify, JSONRPC.notification(method, params)})
  end

  @doc "Records a resource subscription."
  @spec subscribe(pid(), String.t()) :: :ok
  def subscribe(pid, uri), do: GenServer.cast(pid, {:subscribe, uri})

  @doc "Removes a resource subscription."
  @spec unsubscribe(pid(), String.t()) :: :ok
  def unsubscribe(pid, uri), do: GenServer.cast(pid, {:unsubscribe, uri})

  @doc "Returns the set of subscribed resource URIs."
  @spec subscriptions(pid()) :: MapSet.t()
  def subscriptions(pid), do: GenServer.call(pid, :subscriptions)

  ## GenServer callbacks

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.fetch!(opts, :id),
      server: Keyword.fetch!(opts, :server),
      server_state: Keyword.get(opts, :server_state),
      protocol_version: Keyword.fetch!(opts, :protocol_version),
      client_info: Keyword.get(opts, :client_info),
      client_capabilities: Keyword.get(opts, :client_capabilities, %{}),
      initialized: false,
      min_log_level: Keyword.get(opts, :min_log_level, "info"),
      subscriptions: MapSet.new(),
      general_owner: nil,
      general_ref: nil,
      general_stream_id: "g0",
      general_seq: 0,
      general_buffer: [],
      buffer_limit: Keyword.get(opts, :buffer_limit, @default_buffer_limit),
      inflight: %{},
      cancelled: MapSet.new(),
      outbound: %{},
      outbound_seq: 0,
      post_seq: 0,
      idle_timeout: Keyword.get(opts, :idle_timeout),
      last_active: System.monotonic_time(:millisecond)
    }

    # The idle check polls `last_active` (updated by `touch/1` on every client interaction);
    # the max-lifetime cap fires once regardless of activity.
    if is_integer(state.idle_timeout),
      do: Process.send_after(self(), :idle_check, state.idle_timeout)

    case Keyword.get(opts, :max_lifetime) do
      ms when is_integer(ms) -> Process.send_after(self(), :max_lifetime, ms)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      session: self(),
      server: state.server,
      server_state: state.server_state,
      protocol_version: state.protocol_version,
      client_info: state.client_info,
      client_capabilities: state.client_capabilities,
      min_log_level: state.min_log_level
    }

    {:reply, snapshot, touch(state)}
  end

  def handle_call({:start_request, request_id, task_pid, owner_pid}, _from, state) do
    seq = state.post_seq + 1
    stream_id = "p" <> Integer.to_string(seq)
    state = touch(%{state | post_seq: seq})

    # If a cancellation for this id arrived before the request was registered, kill the
    # task immediately rather than letting it run unobserved.
    if MapSet.member?(state.cancelled, request_id) do
      Process.exit(task_pid, :kill)
      {:reply, stream_id, state}
    else
      inflight = Map.put(state.inflight, request_id, %{task: task_pid, owner: owner_pid})
      {:reply, stream_id, %{state | inflight: inflight}}
    end
  end

  def handle_call({:cancelled?, request_id}, _from, state) do
    {:reply, MapSet.member?(state.cancelled, request_id), state}
  end

  def handle_call({:register_outbound, caller}, _from, state) do
    seq = state.outbound_seq + 1
    id = "srv-" <> Integer.to_string(seq)
    # Monitor the caller so a killed handler (timeout/cancellation) does not leak its
    # pending outbound entry.
    ref = Process.monitor(caller)
    outbound = Map.put(state.outbound, id, {caller, ref})
    {:reply, id, %{state | outbound_seq: seq, outbound: outbound}}
  end

  def handle_call({:register_general_stream, owner, resume_from}, _from, state) do
    # Tell a previously-registered GET stream owner to stop so it does not leak.
    if state.general_owner, do: send(state.general_owner, :mcp_close)
    if state.general_ref, do: Process.demonitor(state.general_ref, [:flush])
    ref = Process.monitor(owner)

    replay =
      case resume_from do
        {stream_id, seq} when stream_id == state.general_stream_id ->
          state.general_buffer
          |> Enum.filter(fn {s, _json} -> s > seq end)
          |> Enum.sort_by(fn {s, _json} -> s end)
          |> Enum.map(fn {s, json} -> {SSE.event_id(state.general_stream_id, s), json} end)

        _ ->
          []
      end

    {:reply, {:ok, state.general_stream_id, replay},
     touch(%{state | general_owner: owner, general_ref: ref})}
  end

  def handle_call(:subscriptions, _from, state), do: {:reply, state.subscriptions, state}

  @impl true
  def handle_cast({:finish_request, request_id}, state) do
    {:noreply,
     touch(%{
       state
       | inflight: Map.delete(state.inflight, request_id),
         cancelled: MapSet.delete(state.cancelled, request_id)
     })}
  end

  def handle_cast({:cancel_outbound, id}, state) do
    {:noreply, %{state | outbound: drop_outbound(state.outbound, id)}}
  end

  def handle_cast({:set_log_level, level}, state) do
    {:noreply, %{state | min_log_level: level}}
  end

  def handle_cast({:subscribe, uri}, state) do
    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, uri)}}
  end

  def handle_cast({:unsubscribe, uri}, state) do
    {:noreply, %{state | subscriptions: MapSet.delete(state.subscriptions, uri)}}
  end

  def handle_cast({:notify, message}, state) do
    {:noreply, push_general(state, message)}
  end

  def handle_cast({:client_message, message}, state) do
    {:noreply, touch(handle_client(message, state))}
  end

  @impl true
  def handle_info(:idle_check, state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_active

    cond do
      # Never reap a session that is still serving a request; re-check later.
      map_size(state.inflight) > 0 -> {:noreply, schedule_idle_check(state, state.idle_timeout)}
      elapsed >= state.idle_timeout -> {:stop, :normal, state}
      true -> {:noreply, schedule_idle_check(state, state.idle_timeout - elapsed)}
    end
  end

  def handle_info(:max_lifetime, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{general_ref: ref} = state) do
    {:noreply, %{state | general_owner: nil, general_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Drop any pending outbound request whose awaiting caller has died.
    outbound =
      :maps.filter(fn _id, {_caller, r} -> r != ref end, state.outbound)

    {:noreply, %{state | outbound: outbound}}
  end

  # Records client activity for the idle check; the periodic :idle_check message reads it.
  defp touch(state), do: %{state | last_active: System.monotonic_time(:millisecond)}

  defp schedule_idle_check(state, after_ms) do
    Process.send_after(self(), :idle_check, max(after_ms, 1))
    state
  end

  ## Internal: client message handling

  defp handle_client({:notification, "notifications/initialized", _params}, state) do
    %{state | initialized: true}
  end

  defp handle_client({:notification, "notifications/cancelled", params}, state) do
    request_id = Map.get(params, "requestId")
    cancel_request(state, request_id)
  end

  defp handle_client({:notification, _method, _params}, state), do: state

  defp handle_client({:response, id, result}, state) do
    deliver_outbound(state, id, {:mcp_reply, id, result})
  end

  defp handle_client({:error_response, id, error}, state) do
    mcp_error =
      Error.new(
        Map.get(error, "code", -32_603),
        Map.get(error, "message", "error"),
        Map.get(error, "data")
      )

    deliver_outbound(state, id, {:mcp_error, id, mcp_error})
  end

  defp handle_client(_other, state), do: state

  defp cancel_request(state, nil), do: state

  defp cancel_request(state, request_id) do
    case Map.fetch(state.inflight, request_id) do
      {:ok, %{task: task}} ->
        # Killing the monitored task makes the owning Plug observe a :killed DOWN and
        # respond with a cancellation error; no separate owner message is needed.
        Process.exit(task, :kill)

        %{
          state
          | inflight: Map.delete(state.inflight, request_id),
            cancelled: MapSet.put(state.cancelled, request_id)
        }

      :error ->
        %{state | cancelled: MapSet.put(state.cancelled, request_id)}
    end
  end

  defp deliver_outbound(state, id, message) do
    case Map.fetch(state.outbound, id) do
      {:ok, {caller, ref}} ->
        Process.demonitor(ref, [:flush])
        send(caller, message)
        %{state | outbound: Map.delete(state.outbound, id)}

      :error ->
        state
    end
  end

  defp drop_outbound(outbound, id) do
    case Map.fetch(outbound, id) do
      {:ok, {_caller, ref}} ->
        Process.demonitor(ref, [:flush])
        Map.delete(outbound, id)

      :error ->
        outbound
    end
  end

  ## Internal: general stream delivery + resumability buffer

  defp push_general(state, message) do
    seq = state.general_seq + 1
    json = JSONRPC.encode!(message)
    buffer = Enum.take([{seq, json} | state.general_buffer], state.buffer_limit)
    state = %{state | general_seq: seq, general_buffer: buffer}

    if state.general_owner do
      send(state.general_owner, {:mcp_event, SSE.event_id(state.general_stream_id, seq), json})
    end

    state
  end
end
