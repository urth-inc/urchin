defmodule Urchin.ResourceTemplate do
  @moduledoc """
  A resource template advertised via `resources/templates/list`.

  Mirrors the `ResourceTemplate` type from the MCP schema. `uri_template` is an
  RFC 6570 URI template.
  """

  alias Urchin.WireFormat

  @enforce_keys [:uri_template, :name]
  defstruct [
    :uri_template,
    :name,
    :title,
    :description,
    :mime_type,
    :annotations,
    :icons,
    :meta
  ]

  @type t :: %__MODULE__{
          uri_template: String.t(),
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          annotations: map() | nil,
          icons: [map()] | nil,
          meta: map() | nil
        }

  @doc "Builds a resource template from a keyword list or map of attributes."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      uri_template: fetch!(attrs, :uri_template),
      name: fetch!(attrs, :name),
      title: attrs[:title],
      description: attrs[:description],
      mime_type: attrs[:mime_type],
      annotations: attrs[:annotations],
      icons: attrs[:icons],
      meta: attrs[:meta]
    }
  end

  defp fetch!(attrs, key) do
    case attrs do
      %{^key => value} when is_binary(value) -> value
      _ -> raise(ArgumentError, "resource template requires a string :#{key}")
    end
  end

  @doc "Serializes the resource template to its JSON-RPC wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = template) do
    %{uriTemplate: template.uri_template, name: template.name}
    |> WireFormat.maybe_put(:title, template.title)
    |> WireFormat.maybe_put(:description, template.description)
    |> WireFormat.maybe_put(:mimeType, template.mime_type)
    |> WireFormat.maybe_put(:annotations, template.annotations)
    |> WireFormat.maybe_put(:icons, template.icons)
    |> WireFormat.maybe_put(:_meta, template.meta)
  end

  defimpl Jason.Encoder do
    def encode(template, opts) do
      template |> Urchin.ResourceTemplate.to_map() |> Jason.Encode.map(opts)
    end
  end
end
