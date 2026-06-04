defmodule Urchin.Prompt do
  @moduledoc """
  A prompt definition advertised via `prompts/list`, plus helpers for building the
  `PromptMessage` list returned by `prompts/get`.

  Mirrors the `Prompt`, `PromptArgument` and `PromptMessage` types from the schema.
  """

  alias Urchin.WireFormat

  defmodule Argument do
    @moduledoc "An argument accepted by a prompt template."

    alias Urchin.WireFormat

    @enforce_keys [:name]
    defstruct [:name, :title, :description, :required]

    @type t :: %__MODULE__{
            name: String.t(),
            title: String.t() | nil,
            description: String.t() | nil,
            required: boolean() | nil
          }

    @doc "Builds a prompt argument from a keyword list or map."
    @spec new(keyword() | map()) :: t()
    def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

    def new(%{name: name} = attrs) when is_binary(name) do
      %__MODULE__{
        name: name,
        title: attrs[:title],
        description: attrs[:description],
        required: attrs[:required]
      }
    end

    def new(_), do: raise(ArgumentError, "prompt argument requires a string :name")

    @doc "Serializes the argument to its wire shape."
    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = arg) do
      %{name: arg.name}
      |> WireFormat.maybe_put(:title, arg.title)
      |> WireFormat.maybe_put(:description, arg.description)
      |> WireFormat.maybe_put(:required, arg.required)
    end

    defimpl Jason.Encoder do
      def encode(arg, opts), do: arg |> Urchin.Prompt.Argument.to_map() |> Jason.Encode.map(opts)
    end
  end

  @enforce_keys [:name]
  defstruct [:name, :title, :description, :arguments, :icons, :meta]

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          arguments: [Argument.t()] | nil,
          icons: [map()] | nil,
          meta: map() | nil
        }

  @doc "Builds a prompt from a keyword list or map of attributes."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(%{name: name} = attrs) when is_binary(name) do
    %__MODULE__{
      name: name,
      title: attrs[:title],
      description: attrs[:description],
      arguments: normalize_arguments(attrs[:arguments]),
      icons: attrs[:icons],
      meta: attrs[:meta]
    }
  end

  def new(_), do: raise(ArgumentError, "prompt requires a string :name")

  defp normalize_arguments(nil), do: nil
  defp normalize_arguments(args) when is_list(args), do: Enum.map(args, &to_argument/1)

  defp to_argument(%Argument{} = arg), do: arg
  defp to_argument(attrs), do: Argument.new(attrs)

  @doc "Serializes the prompt to its JSON-RPC wire shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = prompt) do
    %{name: prompt.name}
    |> WireFormat.maybe_put(:title, prompt.title)
    |> WireFormat.maybe_put(:description, prompt.description)
    |> WireFormat.maybe_put(:arguments, encode_arguments(prompt.arguments))
    |> WireFormat.maybe_put(:icons, prompt.icons)
    |> WireFormat.maybe_put(:_meta, prompt.meta)
  end

  defp encode_arguments(nil), do: nil
  defp encode_arguments(args), do: Enum.map(args, &Argument.to_map/1)

  @doc "Builds a `PromptMessage` with the `user` role."
  @spec user_message(Urchin.Content.block()) :: map()
  def user_message(content), do: message("user", content)

  @doc "Builds a `PromptMessage` with the `assistant` role."
  @spec assistant_message(Urchin.Content.block()) :: map()
  def assistant_message(content), do: message("assistant", content)

  @doc "Builds a `PromptMessage` with an explicit role (`\"user\"` or `\"assistant\"`)."
  @spec message(String.t(), Urchin.Content.block()) :: map()
  def message(role, content) when role in ["user", "assistant"] and is_map(content) do
    %{role: role, content: content}
  end

  defimpl Jason.Encoder do
    def encode(prompt, opts), do: prompt |> Urchin.Prompt.to_map() |> Jason.Encode.map(opts)
  end
end
