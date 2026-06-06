defmodule Urchin.Context do
  @moduledoc """
  The request context handed to every server handler.

  Besides carrying the negotiated session metadata and the user state from
  `c:Urchin.Server.init/1`, the context exposes the side-effecting capabilities a
  handler may use while processing a request:

    * progress and log notifications related to the in-flight request
    * server-initiated requests to the client: sampling, elicitation, roots
    * a best-effort cancellation check

  Notifications and server-initiated requests are emitted on the stream that carries
  the originating request, as required by the transport spec.
  """

  alias Urchin.{Error, JSONRPC}

  @log_levels ~w(debug info notice warning error critical alert emergency)
  @log_severity @log_levels |> Enum.with_index() |> Map.new()

  defstruct [
    :session,
    :owner,
    :request_id,
    :progress_token,
    :protocol_version,
    :client_info,
    :client_capabilities,
    :state,
    :uri,
    :auth,
    params: %{},
    assigns: %{},
    min_log_level: "debug",
    expose_internal_errors: false,
    validate_arguments: false,
    initialized: false,
    enforce_initialized: false,
    tool_errors: :json_rpc,
    cancelled_ref: nil
  ]

  @type t :: %__MODULE__{
          session: pid() | nil,
          owner: pid() | nil,
          request_id: JSONRPC.id() | nil,
          progress_token: String.t() | number() | nil,
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map() | nil,
          state: term(),
          uri: String.t() | nil,
          auth: Urchin.Auth.Claims.t() | nil,
          params: map(),
          assigns: map(),
          min_log_level: String.t(),
          expose_internal_errors: boolean(),
          validate_arguments: boolean(),
          initialized: boolean(),
          enforce_initialized: boolean(),
          tool_errors: :json_rpc | :result,
          cancelled_ref: reference() | nil
        }

  @default_request_timeout 30_000

  @doc "Returns the valid MCP log levels, in increasing severity order."
  @spec log_levels() :: [String.t()]
  def log_levels, do: @log_levels

  @doc "Returns the user state established by `c:Urchin.Server.init/1`."
  @spec state(t()) :: term()
  def state(%__MODULE__{state: state}), do: state

  @doc """
  Returns the validated OAuth claims for the originating request, or `nil`.

  Populated only when the transport is configured with `:auth` (or an upstream
  `Urchin.Auth.Plug` ran). Handlers use it for per-tool authorization:

      if Urchin.Auth.Claims.has_scope?(Urchin.Context.auth(ctx), "files:write") do
        # ...
      end
  """
  @spec auth(t()) :: Urchin.Auth.Claims.t() | nil
  def auth(%__MODULE__{auth: auth}), do: auth

  @doc "Stores a value in the context assigns."
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = ctx, key, value) when is_atom(key) do
    %{ctx | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Sends a progress notification for the originating request.

  No-op when the client did not supply a `progressToken` for the request.

  ## Options
    * `:total` - total units of work, if known
    * `:message` - human-readable progress message
  """
  @spec progress(t(), number(), keyword()) :: :ok
  def progress(%__MODULE__{progress_token: nil}, _progress, _opts), do: :ok

  def progress(%__MODULE__{progress_token: token} = ctx, progress, opts)
      when is_number(progress) do
    params =
      %{progressToken: token, progress: progress}
      |> put_optional(:total, opts[:total])
      |> put_optional(:message, opts[:message])

    emit(ctx, JSONRPC.notification("notifications/progress", params))
  end

  @doc """
  Sends a `notifications/message` log entry to the client.

  Messages below the level requested by the client via `logging/setLevel` are
  dropped. `level` is one of #{inspect(@log_levels)}.

  ## Options
    * `:logger` - optional logger name
  """
  @spec log(t(), String.t(), term(), keyword()) :: :ok
  def log(%__MODULE__{} = ctx, level, data, opts \\ []) when level in @log_levels do
    if log_enabled?(ctx, level) do
      params =
        %{level: level, data: data}
        |> put_optional(:logger, opts[:logger])

      emit(ctx, JSONRPC.notification("notifications/message", params))
    else
      :ok
    end
  end

  @doc "Sends an arbitrary JSON-RPC notification on the originating request stream."
  @spec notify(t(), String.t(), map() | nil) :: :ok
  def notify(%__MODULE__{} = ctx, method, params \\ nil) do
    emit(ctx, JSONRPC.notification(method, params))
  end

  @doc """
  Issues a `sampling/createMessage` request to the client and waits for the result.

  Returns `{:ok, result_map}` or `{:error, Urchin.Error.t()}`. Returns an error without
  contacting the client when it did not advertise the `sampling` capability.
  """
  @spec create_message(t(), map(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def create_message(ctx, params, timeout \\ @default_request_timeout) do
    with :ok <- require_capability(ctx, "sampling") do
      request(ctx, "sampling/createMessage", params, timeout)
    end
  end

  @doc """
  Issues an `elicitation/create` request to the client and waits for the result.

  Returns `{:ok, result_map}` or `{:error, Urchin.Error.t()}`. Returns an error without
  contacting the client when it did not advertise the `elicitation` capability.
  """
  @spec elicit(t(), map(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def elicit(ctx, params, timeout \\ @default_request_timeout) do
    with :ok <- require_capability(ctx, "elicitation") do
      request(ctx, "elicitation/create", params, timeout)
    end
  end

  @doc """
  Issues a `roots/list` request to the client and waits for the result.

  Returns `{:ok, %{"roots" => [...]}}` or `{:error, Urchin.Error.t()}`. Returns an error
  without contacting the client when it did not advertise the `roots` capability.
  """
  @spec list_roots(t(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def list_roots(ctx, timeout \\ @default_request_timeout) do
    with :ok <- require_capability(ctx, "roots") do
      request(ctx, "roots/list", nil, timeout)
    end
  end

  @doc """
  Issues an arbitrary server-to-client request and blocks until the client responds.

  The request is written to the originating request's stream; the matching response,
  delivered on a later client POST, is correlated by the session.
  """
  @spec request(t(), String.t(), map() | nil, timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(%__MODULE__{session: nil}, _method, _params, _timeout) do
    {:error, Error.internal_error("No session is associated with this context")}
  end

  def request(%__MODULE__{session: session, owner: owner}, method, params, timeout) do
    id = Urchin.Session.register_outbound(session, self())
    send(owner, {:mcp_out, JSONRPC.request(id, method, params)})

    receive do
      {:mcp_reply, ^id, result} -> {:ok, result}
      {:mcp_error, ^id, %Error{} = error} -> {:error, error}
    after
      timeout ->
        Urchin.Session.cancel_outbound(session, id)
        {:error, Error.internal_error("Timed out waiting for client response to #{method}")}
    end
  end

  @doc """
  Returns true if the originating request has been cancelled by the client.

  Cancellation also terminates the handler process, so this is a cooperative,
  best-effort check for long-running loops.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{session: nil}), do: false

  def cancelled?(%__MODULE__{session: session, request_id: id}) do
    Urchin.Session.cancelled?(session, id)
  end

  defp require_capability(%__MODULE__{client_capabilities: caps}, name) do
    if is_map(caps) and Map.has_key?(caps, name) do
      :ok
    else
      {:error, Error.invalid_request(~s(Client did not advertise the "#{name}" capability))}
    end
  end

  # Sends an outbound message to the process that owns the originating stream.
  defp emit(%__MODULE__{owner: nil}, _message), do: :ok

  defp emit(%__MODULE__{owner: owner}, message) do
    send(owner, {:mcp_out, message})
    :ok
  end

  defp log_enabled?(%__MODULE__{min_log_level: min}, level) do
    Map.get(@log_severity, level, 0) >= Map.get(@log_severity, min, 0)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
