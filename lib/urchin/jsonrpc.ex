defmodule Urchin.JSONRPC do
  @moduledoc """
  Encoding, decoding and classification of JSON-RPC 2.0 messages.

  The 2025-11-25 revision carries exactly one JSON-RPC message per transport frame
  (HTTP request batching was removed), so this module operates on single messages.

  Decoded messages are returned as tagged tuples so callers can branch on the kind
  without re-inspecting the map:

    * `{:request, id, method, params}`
    * `{:notification, method, params}`
    * `{:response, id, result}`
    * `{:error_response, id, error}`
  """

  alias Urchin.{Error, Protocol}

  @type id :: String.t() | integer()
  @type decoded ::
          {:request, id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:response, id(), term()}
          | {:error_response, id() | nil, map()}

  @doc """
  Parses a JSON binary into a single classified JSON-RPC message.

  Returns `{:ok, decoded}` or `{:error, Urchin.Error.t()}`. Malformed JSON yields a
  parse error; structurally invalid messages yield an invalid-request error.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, term} -> classify(term)
      {:error, %Jason.DecodeError{} = err} -> {:error, Error.parse_error(Exception.message(err))}
    end
  end

  @doc """
  Classifies an already-decoded JSON term (a map) into a tagged message.

  Arrays are rejected: this revision does not support JSON-RPC batching.
  """
  @spec classify(term()) :: {:ok, decoded()} | {:error, Error.t()}
  def classify(term)

  def classify(list) when is_list(list) do
    {:error,
     Error.invalid_request("JSON-RPC batching is not supported in this protocol revision")}
  end

  def classify(%{"jsonrpc" => "2.0"} = msg) do
    do_classify(msg)
  end

  def classify(%{"jsonrpc" => version}) do
    {:error, Error.invalid_request("Unsupported jsonrpc version: #{inspect(version)}")}
  end

  def classify(_other) do
    {:error, Error.invalid_request(~s(Missing "jsonrpc" version field))}
  end

  defp do_classify(%{"method" => method} = msg) when is_binary(method) do
    params = normalize_params(Map.get(msg, "params"))

    case Map.fetch(msg, "id") do
      {:ok, id} when is_binary(id) or is_integer(id) ->
        {:ok, {:request, id, method, params}}

      {:ok, nil} ->
        # An id of null is treated as a notification-shaped message; per JSON-RPC a
        # request id must not be null. Treat it as a notification to stay lenient.
        {:ok, {:notification, method, params}}

      :error ->
        {:ok, {:notification, method, params}}

      {:ok, other} ->
        {:error, Error.invalid_request("Invalid request id: #{inspect(other)}")}
    end
  end

  defp do_classify(%{"result" => result, "id" => id}) when is_binary(id) or is_integer(id) do
    {:ok, {:response, id, result}}
  end

  defp do_classify(%{"error" => %{} = error} = msg) do
    {:ok, {:error_response, Map.get(msg, "id"), error}}
  end

  defp do_classify(_msg) do
    {:error, Error.invalid_request("Message is neither a request, notification nor response")}
  end

  defp normalize_params(nil), do: %{}
  defp normalize_params(params) when is_map(params), do: params
  # Positional params (a list) are valid JSON-RPC but unused by MCP; pass through.
  defp normalize_params(params) when is_list(params), do: params

  @doc "Builds a JSON-RPC request map."
  @spec request(id(), String.t(), map() | nil) :: map()
  def request(id, method, params \\ nil) do
    base = %{jsonrpc: Protocol.jsonrpc_version(), id: id, method: method}
    if params in [nil, %{}], do: base, else: Map.put(base, :params, params)
  end

  @doc "Builds a JSON-RPC notification map."
  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) do
    base = %{jsonrpc: Protocol.jsonrpc_version(), method: method}
    if params in [nil, %{}], do: base, else: Map.put(base, :params, params)
  end

  @doc "Builds a successful JSON-RPC response map."
  @spec result(id(), term()) :: map()
  def result(id, result) do
    %{jsonrpc: Protocol.jsonrpc_version(), id: id, result: result}
  end

  @doc """
  Builds a JSON-RPC error response map. `id` may be nil for errors that cannot be
  associated with a request (e.g. parse errors), serialized as JSON `null`.
  """
  @spec error_response(id() | nil, Error.t()) :: map()
  def error_response(id, %Error{} = error) do
    %{jsonrpc: Protocol.jsonrpc_version(), id: id, error: Error.to_map(error)}
  end

  @doc "Encodes a message map to a JSON binary."
  @spec encode!(map()) :: binary()
  def encode!(message), do: Jason.encode!(message)
end
