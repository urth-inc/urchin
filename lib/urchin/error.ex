defmodule Urchin.Error do
  @moduledoc """
  JSON-RPC / MCP error representation.

  An `Urchin.Error` is both a struct and an exception, so handlers may either return
  `{:error, Urchin.Error.t()}` or `raise` it. The dispatcher converts it into a
  JSON-RPC error object on the wire.
  """

  # Standard JSON-RPC 2.0 error codes.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # MCP implementation-defined code reserved for URL elicitation.
  @url_elicitation_required -32_042

  @enforce_keys [:code, :message]
  defexception [:code, :message, :data]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term() | nil
        }

  @impl Exception
  def message(%__MODULE__{message: message, code: code}) do
    "MCP error #{code}: #{message}"
  end

  @doc "Builds an error with an explicit numeric code."
  @spec new(integer(), String.t(), term() | nil) :: t()
  def new(code, message, data \\ nil) when is_integer(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, data: data}
  end

  @doc "JSON-RPC parse error (-32700): invalid JSON was received."
  @spec parse_error(String.t(), term() | nil) :: t()
  def parse_error(message \\ "Parse error", data \\ nil),
    do: new(@parse_error, message, data)

  @doc "JSON-RPC invalid request (-32600): the payload is not a valid request object."
  @spec invalid_request(String.t(), term() | nil) :: t()
  def invalid_request(message \\ "Invalid Request", data \\ nil),
    do: new(@invalid_request, message, data)

  @doc "JSON-RPC method not found (-32601)."
  @spec method_not_found(String.t(), term() | nil) :: t()
  def method_not_found(message \\ "Method not found", data \\ nil),
    do: new(@method_not_found, message, data)

  @doc "JSON-RPC invalid params (-32602)."
  @spec invalid_params(String.t(), term() | nil) :: t()
  def invalid_params(message \\ "Invalid params", data \\ nil),
    do: new(@invalid_params, message, data)

  @doc "JSON-RPC internal error (-32603)."
  @spec internal_error(String.t(), term() | nil) :: t()
  def internal_error(message \\ "Internal error", data \\ nil),
    do: new(@internal_error, message, data)

  @doc "Code constant for `method_not_found`."
  @spec method_not_found_code() :: integer()
  def method_not_found_code, do: @method_not_found

  @doc "Code constant for the URL-elicitation-required error."
  @spec url_elicitation_required_code() :: integer()
  def url_elicitation_required_code, do: @url_elicitation_required

  @doc """
  Serializes the error into the JSON-RPC `error` object shape. The `data` member
  is omitted when nil.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{code: code, message: message, data: nil}) do
    %{code: code, message: message}
  end

  def to_map(%__MODULE__{code: code, message: message, data: data}) do
    %{code: code, message: message, data: data}
  end

  @doc """
  Coerces an arbitrary value raised or returned by user code into an `Urchin.Error`.

  `Urchin.Error` values pass through unchanged. Everything else becomes an internal
  error so that exceptions never leak transport details to the client.
  """
  @spec wrap(term()) :: t()
  def wrap(%__MODULE__{} = error), do: error
  def wrap(message) when is_binary(message), do: internal_error(message)
  def wrap(other), do: internal_error("Internal error", inspect(other))
end
