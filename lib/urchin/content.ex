defmodule Urchin.Content do
  @moduledoc """
  Builders for MCP content blocks and resource contents.

  Content blocks (`text`, `image`, `audio`, `resource_link`, `embedded`) appear in
  tool-call results and prompt messages. Resource contents (`text_resource`,
  `blob_resource`) appear in `resources/read` results.

  Every builder returns a plain map with atom keys, ready to be JSON-encoded. Optional
  members (`annotations`, `_meta`) are only included when provided.
  """

  @type block :: map()
  @type contents :: map()
  @type opts :: keyword()

  @doc """
  A text content block.

  ## Options
    * `:annotations` - client annotations map
    * `:meta` - value for the `_meta` field
  """
  @spec text(String.t(), opts()) :: block()
  def text(text, opts \\ []) when is_binary(text) do
    %{type: "text", text: text}
    |> put_optional(opts)
  end

  @doc "An image content block carrying base64-encoded data and its MIME type."
  @spec image(String.t(), String.t(), opts()) :: block()
  def image(base64_data, mime_type, opts \\ [])
      when is_binary(base64_data) and is_binary(mime_type) do
    %{type: "image", data: base64_data, mimeType: mime_type}
    |> put_optional(opts)
  end

  @doc "An audio content block carrying base64-encoded data and its MIME type."
  @spec audio(String.t(), String.t(), opts()) :: block()
  def audio(base64_data, mime_type, opts \\ [])
      when is_binary(base64_data) and is_binary(mime_type) do
    %{type: "audio", data: base64_data, mimeType: mime_type}
    |> put_optional(opts)
  end

  @doc """
  A resource link content block. Accepts an `Urchin.Resource` struct or a map carrying
  at least `:uri`/`:name`.
  """
  @spec resource_link(Urchin.Resource.t() | map(), opts()) :: block()
  def resource_link(resource, opts \\ [])

  def resource_link(%Urchin.Resource{} = resource, opts) do
    resource
    |> Urchin.Resource.to_map()
    |> Map.put(:type, "resource_link")
    |> put_optional(opts)
  end

  # A ResourceLink extends Resource, so both :uri and :name are required. Route through
  # Urchin.Resource so missing fields raise and internal snake_case keys are normalized.
  def resource_link(%{uri: uri} = resource, opts) when is_binary(uri) do
    resource
    |> Urchin.Resource.new()
    |> Urchin.Resource.to_map()
    |> Map.put(:type, "resource_link")
    |> put_optional(opts)
  end

  @doc """
  An embedded resource content block. `resource_contents` must be a map built by
  `text_resource/3` or `blob_resource/3` (or an equivalent shape).
  """
  @spec embedded(contents(), opts()) :: block()
  def embedded(resource_contents, opts \\ []) when is_map(resource_contents) do
    %{type: "resource", resource: resource_contents}
    |> put_optional(opts)
  end

  @doc """
  Text resource contents for a `resources/read` result.

  ## Options
    * `:mime_type` - MIME type of the resource
    * `:meta` - value for the `_meta` field
  """
  @spec text_resource(String.t(), String.t(), opts()) :: contents()
  def text_resource(uri, text, opts \\ []) when is_binary(uri) and is_binary(text) do
    %{uri: uri, text: text}
    |> maybe_put(:mimeType, opts[:mime_type])
    |> put_meta(opts)
  end

  @doc """
  Binary resource contents (base64-encoded) for a `resources/read` result.

  ## Options
    * `:mime_type` - MIME type of the resource
    * `:meta` - value for the `_meta` field
  """
  @spec blob_resource(String.t(), String.t(), opts()) :: contents()
  def blob_resource(uri, base64_blob, opts \\ [])
      when is_binary(uri) and is_binary(base64_blob) do
    %{uri: uri, blob: base64_blob}
    |> maybe_put(:mimeType, opts[:mime_type])
    |> put_meta(opts)
  end

  # Adds the optional `annotations` and `_meta` members shared by content blocks.
  defp put_optional(map, opts) do
    map
    |> maybe_put(:annotations, opts[:annotations])
    |> put_meta(opts)
  end

  defp put_meta(map, opts), do: maybe_put(map, :_meta, opts[:meta])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
