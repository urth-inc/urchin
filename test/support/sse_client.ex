defmodule Urchin.Test.SSEClient do
  @moduledoc false
  # A minimal raw-socket HTTP/SSE client for end-to-end transport tests. Uses
  # :gen_tcp so SSE chunks can be read incrementally as they arrive.
  #
  # For streaming assertions it accumulates raw bytes and matches substrings, which is
  # robust against HTTP chunked-transfer framing interleaved with SSE field lines.

  @doc "Returns a free TCP port by briefly binding to port 0."
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc "Performs a buffered HTTP request and returns `{status, headers, body}`."
  def request(port, method, path, headers, body) do
    {:ok, socket} = connect(port)
    :ok = :gen_tcp.send(socket, build_request(method, path, headers, body))
    result = read_until_closed(socket)
    :gen_tcp.close(socket)
    parse_response(result)
  end

  @doc """
  Opens a streaming request and returns an open socket plus the initial bytes read.
  The socket is left open for incremental SSE reads via `recv_until/3`.
  """
  def open(port, method, path, headers, body) do
    {:ok, socket} = connect(port)
    :ok = :gen_tcp.send(socket, build_request(method, path, headers, body))
    {:ok, socket}
  end

  @doc """
  Reads from the socket until the accumulated buffer contains `needle` or the timeout
  elapses. Returns `{:ok, buffer}` or `{:timeout, buffer}`. `acc` carries prior bytes.
  """
  def recv_until(socket, needle, acc \\ "", timeout \\ 2_000) do
    if String.contains?(acc, needle) do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, data} -> recv_until(socket, needle, acc <> data, timeout)
        {:error, _} -> {:timeout, acc}
      end
    end
  end

  def close(socket), do: :gen_tcp.close(socket)

  ## Internals

  defp connect(port) do
    :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
  end

  defp build_request(method, path, headers, body) do
    header_lines = Enum.map_join(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)
    content_length = if body, do: "Content-Length: #{byte_size(body)}\r\n", else: ""

    "#{method} #{path} HTTP/1.1\r\n" <>
      "Host: 127.0.0.1\r\n" <>
      header_lines <>
      content_length <>
      "Connection: close\r\n\r\n" <>
      (body || "")
  end

  defp read_until_closed(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_until_closed(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  defp parse_response(raw) do
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_http, code | _] = String.split(status_line, " ")

    headers =
      Enum.map(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    decoded = if chunked?(headers), do: dechunk(body), else: body
    {String.to_integer(code), headers, decoded}
  end

  defp chunked?(headers) do
    Enum.any?(headers, fn {k, v} ->
      k == "transfer-encoding" and String.contains?(v, "chunked")
    end)
  end

  defp dechunk(body, acc \\ "") do
    case :binary.split(body, "\r\n") do
      [size_hex, rest] ->
        case Integer.parse(size_hex, 16) do
          {0, _} ->
            acc

          {size, _} ->
            case rest do
              <<chunk::binary-size(size), "\r\n", tail::binary>> -> dechunk(tail, acc <> chunk)
              _ -> acc <> rest
            end

          :error ->
            acc <> body
        end

      [_] ->
        acc <> body
    end
  end
end
