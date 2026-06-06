defmodule Urchin.Dispatcher do
  @moduledoc """
  Routes decoded JSON-RPC requests to `Urchin.Server` callbacks and shapes their return
  values into JSON-RPC result maps.

  A method is only honoured when the server module exports the matching callback;
  otherwise a JSON-RPC "method not found" error is returned. User exceptions are
  rescued and converted to errors so transport processes never crash on handler bugs.
  """

  require Logger

  alias Urchin.{Context, Error, Protocol, Result, Session}

  @doc """
  Handles an `initialize` request.

  Returns `{:ok, result_map, session_meta}` where `session_meta` carries the
  negotiated protocol version and the client's declared info/capabilities, or
  `{:error, Urchin.Error.t()}`.
  """
  @spec initialize(module(), map(), Context.t()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def initialize(server, params, ctx) when is_map(params) do
    requested = Map.get(params, "protocolVersion", Protocol.latest_version())
    negotiated = Protocol.negotiate(requested)

    result =
      %{
        protocolVersion: negotiated,
        capabilities: capabilities(server),
        serverInfo: server.server_info()
      }
      |> maybe_put(:instructions, instructions(server))

    meta = %{
      protocol_version: negotiated,
      client_info: Map.get(params, "clientInfo"),
      client_capabilities: Map.get(params, "capabilities", %{})
    }

    {:ok, result, meta}
  rescue
    error in Urchin.Error ->
      {:error, error}

    exception ->
      {:error, handler_error(exception, __STACKTRACE__, ctx, "initialize")}
  end

  def initialize(_server, _params, _ctx) do
    {:error, Error.invalid_params("initialize params must be an object")}
  end

  @doc """
  Handles an operational (post-initialization) request, returning `{:ok, result_map}`
  or `{:error, Urchin.Error.t()}`.
  """
  @spec handle_request(module(), String.t(), map(), Context.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def handle_request(_server, _method, params, _ctx) when not is_map(params) do
    # MCP params are always JSON objects; positional (array) params are invalid.
    {:error, Error.invalid_params("params must be a JSON object")}
  end

  def handle_request(server, method, params, ctx) do
    # Lifecycle gate: when enforce_initialized is on and notifications/initialized has not been
    # received, reject operation requests other than ping with invalid_request.
    with :ok <- check_initialized(method, ctx) do
      do_handle(server, method, params, ctx)
    end
  rescue
    error in Urchin.Error ->
      {:error, error}

    exception ->
      {:error, handler_error(exception, __STACKTRACE__, ctx, "request #{method}")}
  catch
    :throw, value ->
      Logger.error("Urchin handler for #{method} threw: #{inspect(value)}")
      {:error, Error.internal_error(generic_or(ctx, "Handler threw: " <> inspect(value)))}
  end

  # The gate is a no-op unless :enforce_initialized is set and the session is not yet
  # initialized. `notifications/initialized` is a notification routed straight into the
  # session, so it never reaches this request-only path.
  defp check_initialized(_method, %Context{enforce_initialized: false}), do: :ok
  defp check_initialized(_method, %Context{initialized: true}), do: :ok

  defp check_initialized(method, %Context{}) do
    if pre_init_allowed?(method) do
      :ok
    else
      {:error,
       Error.invalid_request(
         "Server not initialized: send notifications/initialized before #{method}"
       )}
    end
  end

  # Only ping is allowed before the client sends notifications/initialized; per the MCP
  # lifecycle a client should not send other requests until initialization completes.
  defp pre_init_allowed?("ping"), do: true
  defp pre_init_allowed?(_method), do: false

  # ping is always available regardless of declared capabilities.
  defp do_handle(_server, "ping", _params, _ctx), do: {:ok, %{}}

  defp do_handle(server, "tools/list", params, ctx) do
    with_callback(server, :list_tools, 2, fn ->
      server.list_tools(cursor(params), ctx) |> list_result(:tools, ctx)
    end)
  end

  defp do_handle(server, "tools/call", params, ctx) do
    with_callback(server, :call_tool, 3, fn ->
      name = require_string(params, "name")
      args = Map.get(params, "arguments", %{})
      call_tool_result(server, name, args, %{ctx | progress_token: progress_token(params)})
    end)
  end

  defp do_handle(server, "resources/list", params, ctx) do
    with_callback(server, :list_resources, 2, fn ->
      server.list_resources(cursor(params), ctx) |> list_result(:resources, ctx)
    end)
  end

  defp do_handle(server, "resources/templates/list", params, ctx) do
    with_callback(server, :list_resource_templates, 2, fn ->
      server.list_resource_templates(cursor(params), ctx) |> list_result(:resourceTemplates, ctx)
    end)
  end

  defp do_handle(server, "resources/read", params, ctx) do
    with_callback(server, :read_resource, 2, fn ->
      uri = require_string(params, "uri")

      case server.read_resource(uri, %{ctx | uri: uri}) do
        {:ok, contents} -> {:ok, %{contents: List.wrap(contents)}}
        other -> normalize_error(other, ctx)
      end
    end)
  end

  defp do_handle(server, "resources/subscribe", params, ctx) do
    with_callback(server, :subscribe_resource, 2, fn ->
      uri = require_string(params, "uri")
      empty_result(server.subscribe_resource(uri, %{ctx | uri: uri}), ctx)
    end)
  end

  defp do_handle(server, "resources/unsubscribe", params, ctx) do
    with_callback(server, :unsubscribe_resource, 2, fn ->
      uri = require_string(params, "uri")
      empty_result(server.unsubscribe_resource(uri, %{ctx | uri: uri}), ctx)
    end)
  end

  defp do_handle(server, "prompts/list", params, ctx) do
    with_callback(server, :list_prompts, 2, fn ->
      server.list_prompts(cursor(params), ctx) |> list_result(:prompts, ctx)
    end)
  end

  defp do_handle(server, "prompts/get", params, ctx) do
    with_callback(server, :get_prompt, 3, fn ->
      name = require_string(params, "name")
      args = Map.get(params, "arguments", %{})

      case server.get_prompt(name, args, ctx) do
        {:ok, messages} ->
          {:ok, %{messages: messages}}

        {:ok, messages, description} ->
          {:ok, maybe_put(%{messages: messages}, :description, description)}

        other ->
          normalize_error(other, ctx)
      end
    end)
  end

  defp do_handle(server, "completion/complete", params, ctx) do
    with_callback(server, :complete, 4, fn ->
      ref = require_map(params, "ref")
      argument = require_map(params, "argument")
      completion_context = Map.get(params, "context", %{})

      case server.complete(ref, argument, completion_context, ctx) do
        {:ok, completion} -> {:ok, %{completion: completion(completion)}}
        other -> normalize_error(other, ctx)
      end
    end)
  end

  defp do_handle(server, "logging/setLevel", params, ctx) do
    # logging/setLevel is a library builtin, available only when the server advertises the
    # logging capability. The level is validated, the optional set_log_level/2 hook runs, and
    # the session level is updated only after both succeed, so a failed call leaves no change.
    if logging_advertised?(server) do
      level = require_string(params, "level")

      with :ok <- validate_log_level(level),
           :ok <- run_log_level_hook(server, level, ctx),
           :ok <- set_session_log_level(ctx, level) do
        {:ok, %{}}
      end
    else
      {:error, Error.method_not_found("Server does not support logging/setLevel")}
    end
  end

  defp do_handle(_server, method, _params, _ctx) do
    {:error, Error.method_not_found("Method not found: " <> method)}
  end

  ## Result shaping

  defp call_tool_result(server, name, args, ctx) do
    case server.call_tool(name, args, ctx) do
      {:ok, %Result.CallTool{} = result} -> {:ok, Result.CallTool.to_map(result)}
      %Result.CallTool{} = result -> {:ok, Result.CallTool.to_map(result)}
      {:ok, content} when is_list(content) -> {:ok, %{content: content, isError: false}}
      {:ok, content, opts} when is_list(content) -> {:ok, call_tool_map(content, opts)}
      {:error, {:invalid_tool_input, reason}} -> invalid_tool_input(reason, ctx)
      other -> tool_error_result(other, ctx)
    end
  rescue
    exception ->
      # A tool that raises reports a tool-execution error so the model can self-correct.
      Logger.error(
        "Urchin tool #{name} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      text = generic_or(ctx, Exception.message(exception), "Tool execution failed")
      {:ok, %{content: [Urchin.Content.text(text)], isError: true}}
  end

  # With tool_errors: :result, a handler's {:error, binary} becomes an isError tool result
  # (so the model can self-correct) instead of a JSON-RPC error. A protocol-level
  # {:error, %Error{}} and every other shape still go through normalize_error.
  defp tool_error_result({:error, message}, %Context{tool_errors: :result})
       when is_binary(message) do
    {:ok, %{content: [Urchin.Content.text(message)], isError: true}}
  end

  defp tool_error_result(other, ctx), do: normalize_error(other, ctx)

  # An input-schema validation failure (:validate_arguments) is a tool-execution error per the MCP
  # tool error semantics: with tool_errors: :result it is an isError CallToolResult so the model can
  # self-correct; with :json_rpc it stays a JSON-RPC invalid_params error (the legacy behavior).
  defp invalid_tool_input(reason, %Context{tool_errors: :result}) do
    {:ok, %{content: [Urchin.Content.text(reason)], isError: true}}
  end

  defp invalid_tool_input(reason, _ctx), do: {:error, Error.invalid_params(reason)}

  defp call_tool_map(content, opts) do
    %{content: content, isError: opts[:is_error] || false}
    |> maybe_put(:structuredContent, opts[:structured_content])
  end

  defp list_result({:ok, items}, key, _ctx) when is_list(items), do: {:ok, %{key => items}}
  defp list_result({:ok, items, nil}, key, _ctx) when is_list(items), do: {:ok, %{key => items}}

  defp list_result({:ok, items, cursor}, key, _ctx) when is_list(items),
    do: {:ok, %{key => items, :nextCursor => cursor}}

  defp list_result(other, _key, ctx), do: normalize_error(other, ctx)

  defp empty_result(:ok, _ctx), do: {:ok, %{}}
  defp empty_result({:ok, _}, _ctx), do: {:ok, %{}}
  defp empty_result(other, ctx), do: normalize_error(other, ctx)

  defp completion(values) when is_list(values), do: %{values: values}

  defp completion(%{} = completion) do
    %{values: get_either(completion, :values, "values", [])}
    |> maybe_put(:total, get_either(completion, :total, "total", nil))
    |> maybe_put(:hasMore, get_either(completion, :has_more, "hasMore", nil))
  end

  # Reads a value that may be keyed by atom or string, preserving false/0 values.
  defp get_either(map, atom_key, string_key, default) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key, default)
    end
  end

  # Deliberate errors pass through: an Urchin.Error and an {:error, binary} message are the
  # handler's choice. A non-binary error reason or an unexpected return value may carry
  # internals, so it is logged and redacted unless :expose_internal_errors is set.
  defp normalize_error({:error, %Error{} = error}, _ctx), do: {:error, error}

  defp normalize_error({:error, message}, _ctx) when is_binary(message),
    do: {:error, Error.internal_error(message)}

  defp normalize_error({:error, reason}, ctx) do
    detail = inspect(reason)
    Logger.error("Urchin handler returned an error reason: #{detail}")
    {:error, Error.internal_error(generic_or(ctx, detail))}
  end

  defp normalize_error(other, ctx) do
    detail = "Invalid handler return: " <> inspect(other)
    Logger.error("Urchin handler returned an invalid value: #{detail}")
    {:error, Error.internal_error(generic_or(ctx, detail))}
  end

  ## Helpers

  defp with_callback(server, fun, arity, callback) do
    if exported?(server, fun, arity) do
      callback.()
    else
      {:error, Error.method_not_found("Server does not support #{fun}")}
    end
  end

  # Apply the client-requested log level to the session when one exists; a nil session
  # (e.g. a handler invoked in a unit test) is a no-op. If the session died mid-request,
  # surface a clean error rather than a generic crash from the GenServer.call exit.
  defp set_session_log_level(%Context{session: session}, level) when is_pid(session) do
    Session.set_log_level(session, level)
    :ok
  catch
    :exit, _ -> {:error, Error.invalid_request("Session not found")}
  end

  defp set_session_log_level(_ctx, _level), do: :ok

  # logging/setLevel is offered only when the server advertises the logging capability.
  # Accept both atom (DSL-derived) and string (hand-written, JSON-shaped) capability keys.
  defp logging_advertised?(server) do
    caps = capabilities(server)
    Map.has_key?(caps, :logging) or Map.has_key?(caps, "logging")
  end

  defp validate_log_level(level) do
    if level in Context.log_levels() do
      :ok
    else
      {:error, Error.invalid_params("Invalid log level: " <> level)}
    end
  end

  # Runs the optional set_log_level/2 hook; a missing hook is a no-op success.
  defp run_log_level_hook(server, level, ctx) do
    if exported?(server, :set_log_level, 2) do
      case server.set_log_level(level, ctx) do
        :ok -> :ok
        {:ok, _} -> :ok
        other -> normalize_error(other, ctx)
      end
    else
      :ok
    end
  end

  defp capabilities(server) do
    if exported?(server, :capabilities, 0), do: server.capabilities(), else: %{}
  end

  defp instructions(server) do
    if exported?(server, :instructions, 0), do: server.instructions(), else: nil
  end

  # `function_exported?/3` returns false for a module that is available but not yet
  # loaded, so ensure the module is loaded before probing for callbacks.
  defp exported?(server, fun, arity) do
    Code.ensure_loaded?(server) and function_exported?(server, fun, arity)
  end

  defp cursor(params), do: Map.get(params, "cursor")

  defp progress_token(params) do
    case params do
      %{"_meta" => %{"progressToken" => token}} -> token
      _ -> nil
    end
  end

  defp require_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> raise Error.invalid_params(~s(Missing or invalid string param "#{key}"))
    end
  end

  defp require_map(params, key) do
    case Map.get(params, key) do
      value when is_map(value) -> value
      _ -> raise Error.invalid_params(~s(Missing or invalid object param "#{key}"))
    end
  end

  # Rescued exceptions are always logged in full but, by default, are not surfaced to the
  # client. Set the transport's :expose_internal_errors to return the message instead.
  defp handler_error(exception, stacktrace, ctx, label) do
    Logger.error("Urchin #{label} crashed: " <> Exception.format(:error, exception, stacktrace))
    Error.internal_error(generic_or(ctx, Exception.message(exception)))
  end

  defp generic_or(ctx, detail, generic \\ "Internal server error")
  defp generic_or(%Context{expose_internal_errors: true}, detail, _generic), do: detail
  defp generic_or(_ctx, _detail, generic), do: generic

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
