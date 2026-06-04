defmodule Urchin.SSE do
  @moduledoc """
  Server-Sent Events framing helpers for the Streamable HTTP transport.

  Event IDs are namespaced per stream (`<stream_id>:<seq>`) so the server can map a
  `Last-Event-ID` back to the originating stream during resumption, as the transport
  spec requires.
  """

  @doc "Builds a per-stream event id of the form `<stream_id>:<seq>`."
  @spec event_id(String.t(), non_neg_integer()) :: String.t()
  def event_id(stream_id, seq), do: "#{stream_id}:#{seq}"

  @doc """
  Parses a `Last-Event-ID` value into `{stream_id, seq}`.

  Returns `:error` when the value is not a recognised per-stream id.
  """
  @spec parse_event_id(String.t()) :: {String.t(), non_neg_integer()} | :error
  def parse_event_id(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [stream_id, seq] ->
        case Integer.parse(seq) do
          {n, ""} -> {stream_id, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Formats a JSON-RPC message as an SSE event with the given id.

  The JSON payload is emitted on a single `data:` line (JSON never contains raw
  newlines once encoded).
  """
  @spec message(String.t(), iodata()) :: iodata()
  def message(id, json) do
    ["id: ", id, "\n", "data: ", json, "\n\n"]
  end

  @doc """
  Builds the priming event: an event id with an empty `data` field, sent first so the
  client can immediately reconnect using that id as `Last-Event-ID`.
  """
  @spec priming(String.t()) :: iodata()
  def priming(id) do
    ["id: ", id, "\n", "data: \n\n"]
  end

  @doc "Builds a `retry` directive instructing the client how long to wait before reconnecting."
  @spec retry(non_neg_integer()) :: iodata()
  def retry(ms) when is_integer(ms) and ms >= 0 do
    ["retry: ", Integer.to_string(ms), "\n\n"]
  end

  @doc "Builds an SSE comment line, useful as a keep-alive heartbeat."
  @spec comment(String.t()) :: iodata()
  def comment(text), do: [": ", text, "\n\n"]
end
