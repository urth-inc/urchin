defmodule Urchin.WireFormat do
  @moduledoc false
  # Internal helpers shared by the definition structs when serializing to the
  # JSON-RPC wire shape.

  @doc "Removes keys whose value is nil from a map."
  @spec compact(map()) :: map()
  def compact(map) when is_map(map) do
    :maps.filter(fn _key, value -> value != nil end, map)
  end

  @doc "Puts `value` under `key` only when `value` is not nil."
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
