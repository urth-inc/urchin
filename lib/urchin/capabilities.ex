defmodule Urchin.Capabilities do
  @moduledoc """
  Builds the `ServerCapabilities` object returned in the `initialize` result and
  parses the `ClientCapabilities` received from the client.

  A capability group is only advertised when the corresponding feature is enabled,
  matching the schema's "present if supported" semantics.
  """

  alias Urchin.WireFormat

  @type feature_flags :: %{
          optional(:tools) => %{optional(:list_changed) => boolean()},
          optional(:resources) => %{
            optional(:subscribe) => boolean(),
            optional(:list_changed) => boolean()
          },
          optional(:prompts) => %{optional(:list_changed) => boolean()},
          optional(:logging) => boolean(),
          optional(:completions) => boolean(),
          optional(:experimental) => map()
        }

  @doc """
  Builds the wire-shape server capabilities map from resolved feature flags.

  Only enabled groups are included. Sub-flags such as `listChanged`/`subscribe`
  default to `false` when omitted.
  """
  @spec server(feature_flags() | keyword()) :: map()
  def server(flags) when is_list(flags), do: server(Map.new(flags))

  def server(flags) when is_map(flags) do
    %{}
    |> put_group(:tools, flags, fn opts ->
      %{} |> WireFormat.maybe_put(:listChanged, truthy(opts[:list_changed]))
    end)
    |> put_group(:resources, flags, fn opts ->
      %{}
      |> WireFormat.maybe_put(:subscribe, truthy(opts[:subscribe]))
      |> WireFormat.maybe_put(:listChanged, truthy(opts[:list_changed]))
    end)
    |> put_group(:prompts, flags, fn opts ->
      %{} |> WireFormat.maybe_put(:listChanged, truthy(opts[:list_changed]))
    end)
    |> put_flag(:logging, flags)
    |> put_flag(:completions, flags)
    |> put_experimental(flags)
  end

  # Adds a capability group (tools/resources/prompts) when present in flags.
  defp put_group(acc, key, flags, builder) do
    case Map.get(flags, key) do
      nil -> acc
      false -> acc
      opts when is_map(opts) -> Map.put(acc, key, builder.(opts))
      true -> Map.put(acc, key, builder.(%{}))
    end
  end

  # Adds a presence-only capability (logging/completions) as an empty object.
  defp put_flag(acc, key, flags) do
    if Map.get(flags, key), do: Map.put(acc, key, %{}), else: acc
  end

  defp put_experimental(acc, flags) do
    case Map.get(flags, :experimental) do
      map when is_map(map) and map_size(map) > 0 -> Map.put(acc, :experimental, map)
      _ -> acc
    end
  end

  # Normalizes a sub-flag: only emit `true`; omit otherwise so the wire stays minimal.
  defp truthy(true), do: true
  defp truthy(_), do: nil
end
