defmodule Urchin.Tool do
  @moduledoc """
  A tool definition advertised via `tools/list`.

  Mirrors the `Tool` type from the MCP schema. `input_schema` is a JSON Schema object
  describing the tool arguments; when omitted it defaults to `default_input_schema/0`, an
  object that accepts no properties.
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
      input_schema: validate_object_schema!(attrs[:input_schema], :input_schema),
      output_schema: validate_object_schema!(attrs[:output_schema], :output_schema),
      annotations: attrs[:annotations],
      execution: attrs[:execution],
      icons: attrs[:icons],
      meta: attrs[:meta]
    }
  end

  defp fetch_name!(%{name: name}) when is_binary(name), do: name
  defp fetch_name!(_), do: raise(ArgumentError, "tool requires a string :name")

  # inputSchema and outputSchema are JSON Schema objects whose root `type` is "object" (MCP tools
  # spec). nil is allowed: input_schema falls back to default_input_schema/0 and output_schema is
  # optional. A non-object schema would advertise a non-conforming tools/list entry.
  defp validate_object_schema!(nil, _field), do: nil

  defp validate_object_schema!(schema, field) when is_map(schema) do
    case schema["type"] || schema[:type] do
      "object" ->
        schema

      other ->
        raise ArgumentError,
              ~s(tool #{field} must be a JSON Schema object with "type": "object", got type: #{inspect(other)})
    end
  end

  defp validate_object_schema!(other, field) do
    raise ArgumentError,
          "tool #{field} must be a map (a JSON Schema object), got: #{inspect(other)}"
  end

  @doc """
  The input schema advertised for a tool that declares none: an object accepting no
  properties, per the MCP recommendation for parameterless tools.
  """
  @spec default_input_schema() :: map()
  def default_input_schema, do: %{"type" => "object", "additionalProperties" => false}

  @doc "Serializes the tool to its JSON-RPC wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool) do
    %{name: tool.name, inputSchema: tool.input_schema || default_input_schema()}
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
