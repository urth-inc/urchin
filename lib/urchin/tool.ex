defmodule Urchin.Tool do
  @moduledoc """
  A tool definition advertised via `tools/list`.

  Mirrors the `Tool` type from the MCP schema. `input_schema` is a JSON Schema object
  describing the tool arguments; when omitted it defaults to an empty object schema.
  """

  alias Urchin.WireFormat

  @enforce_keys [:name]
  defstruct [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :annotations,
    :execution,
    :icons,
    :meta
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map() | nil,
          output_schema: map() | nil,
          annotations: map() | nil,
          execution: map() | nil,
          icons: [map()] | nil,
          meta: map() | nil
        }

  @doc "Builds a tool from a keyword list or map of attributes."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      name: fetch_name!(attrs),
      title: attrs[:title],
      description: attrs[:description],
      input_schema: attrs[:input_schema],
      output_schema: attrs[:output_schema],
      annotations: attrs[:annotations],
      execution: attrs[:execution],
      icons: attrs[:icons],
      meta: attrs[:meta]
    }
  end

  defp fetch_name!(%{name: name}) when is_binary(name), do: name
  defp fetch_name!(_), do: raise(ArgumentError, "tool requires a string :name")

  @doc "Serializes the tool to its JSON-RPC wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool) do
    %{name: tool.name, inputSchema: tool.input_schema || %{"type" => "object"}}
    |> WireFormat.maybe_put(:title, tool.title)
    |> WireFormat.maybe_put(:description, tool.description)
    |> WireFormat.maybe_put(:outputSchema, tool.output_schema)
    |> WireFormat.maybe_put(:annotations, tool.annotations)
    |> WireFormat.maybe_put(:execution, tool.execution)
    |> WireFormat.maybe_put(:icons, tool.icons)
    |> WireFormat.maybe_put(:_meta, tool.meta)
  end

  defimpl Jason.Encoder do
    def encode(tool, opts) do
      tool |> Urchin.Tool.to_map() |> Jason.Encode.map(opts)
    end
  end
end
