defmodule Urchin.Resource do
  @moduledoc """
  A resource definition advertised via `resources/list`.

  Mirrors the `Resource` type from the MCP schema.
  """

  alias Urchin.WireFormat

  @enforce_keys [:uri, :name]
  defstruct [
    :uri,
    :name,
    :title,
    :description,
    :mime_type,
    :annotations,
    :size,
    :icons,
    :meta
  ]

  @type t :: %__MODULE__{
          uri: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          annotations: map() | nil,
          size: non_neg_integer() | nil,
          icons: [map()] | nil,
          meta: map() | nil
        }

  @doc "Builds a resource from a keyword list or map of attributes."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      uri: fetch!(attrs, :uri),
      name: fetch!(attrs, :name),
      title: attrs[:title],
      description: attrs[:description],
      mime_type: attrs[:mime_type],
      annotations: attrs[:annotations],
      size: attrs[:size],
      icons: attrs[:icons],
      meta: attrs[:meta]
    }
  end

  defp fetch!(attrs, key) do
    case attrs do
      %{^key => value} when is_binary(value) -> value
      _ -> raise(ArgumentError, "resource requires a string :#{key}")
    end
  end

  @doc "Serializes the resource to its JSON-RPC wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = resource) do
    %{uri: resource.uri, name: resource.name}
    |> WireFormat.maybe_put(:title, resource.title)
    |> WireFormat.maybe_put(:description, resource.description)
    |> WireFormat.maybe_put(:mimeType, resource.mime_type)
    |> WireFormat.maybe_put(:annotations, resource.annotations)
    |> WireFormat.maybe_put(:size, resource.size)
    |> WireFormat.maybe_put(:icons, resource.icons)
    |> WireFormat.maybe_put(:_meta, resource.meta)
  end

  defimpl Jason.Encoder do
    def encode(resource, opts) do
      resource |> Urchin.Resource.to_map() |> Jason.Encode.map(opts)
    end
  end
end
