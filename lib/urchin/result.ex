defmodule Urchin.Result.CallTool do
  @moduledoc """
  An explicit `tools/call` result.

  Handlers usually return `{:ok, content}` and let the dispatcher build this, but they
  may construct it directly to set `structured_content` or `is_error`.
  """

  alias Urchin.WireFormat

  @enforce_keys [:content]
  defstruct content: [], structured_content: nil, is_error: false

  @type t :: %__MODULE__{
          content: [map()],
          structured_content: map() | nil,
          is_error: boolean()
        }

  @doc "Builds a successful result from a list of content blocks."
  @spec ok([map()], keyword()) :: t()
  def ok(content, opts \\ []) when is_list(content) do
    %__MODULE__{
      content: content,
      structured_content: opts[:structured_content],
      is_error: opts[:is_error] || false
    }
  end

  @doc "Builds an error result (`isError: true`) from a list of content blocks."
  @spec error([map()]) :: t()
  def error(content) when is_list(content) do
    %__MODULE__{content: content, is_error: true}
  end

  @doc "Serializes to the `CallToolResult` wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{content: result.content, isError: result.is_error}
    |> WireFormat.maybe_put(:structuredContent, result.structured_content)
  end

  defimpl Jason.Encoder do
    def encode(result, opts),
      do: result |> Urchin.Result.CallTool.to_map() |> Jason.Encode.map(opts)
  end
end
