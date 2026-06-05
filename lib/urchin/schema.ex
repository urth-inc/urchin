defmodule Urchin.Schema do
  @moduledoc """
  Minimal structural validation of tool arguments against a JSON Schema.

  This is a deliberately small subset of JSON Schema, sufficient to catch the common
  argument mistakes the DSL's `input_schema` describes, without pulling in a full
  validation dependency. It validates `type` (object, array, string, number, integer,
  boolean, null), object `properties` and `required`, array `items`, and `enum`. Other
  keywords (`minLength`, `pattern`, `format`, ...) are ignored rather than enforced.

  For full JSON Schema validation, validate in your handler with a dedicated library
  (e.g. `:ex_json_schema`).
  """

  @doc """
  Validates `value` against `schema`.

  Returns `:ok`, or `{:error, message}` describing the first violation. A `nil` schema
  (or one without a recognized `type`) accepts any value.
  """
  @spec validate(map() | nil, term()) :: :ok | {:error, String.t()}
  def validate(schema, value), do: do_validate(schema, value, "")

  defp do_validate(nil, _value, _path), do: :ok
  defp do_validate(schema, _value, _path) when not is_map(schema), do: :ok

  defp do_validate(schema, value, path) do
    with :ok <- check_type(schema["type"], value, path),
         :ok <- check_enum(schema["enum"], value, path),
         :ok <- check_object(schema, value, path) do
      check_array(schema, value, path)
    end
  end

  ## type

  defp check_type(nil, _value, _path), do: :ok
  defp check_type("object", value, _path) when is_map(value), do: :ok
  defp check_type("array", value, _path) when is_list(value), do: :ok
  defp check_type("string", value, _path) when is_binary(value), do: :ok
  defp check_type("boolean", value, _path) when is_boolean(value), do: :ok
  defp check_type("null", nil, _path), do: :ok
  defp check_type("integer", value, _path) when is_integer(value), do: :ok
  defp check_type("number", value, _path) when is_number(value), do: :ok
  defp check_type(type, value, path), do: {:error, type_error(type, value, path)}

  defp type_error(type, value, path) do
    "#{at(path)}expected #{type}, got #{inspect(value)}"
  end

  ## enum

  defp check_enum(nil, _value, _path), do: :ok

  defp check_enum(allowed, value, path) when is_list(allowed) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{at(path)}value #{inspect(value)} is not one of #{inspect(allowed)}"}
  end

  defp check_enum(_allowed, _value, _path), do: :ok

  ## object: required + properties

  defp check_object(%{"type" => "object"} = schema, value, path) when is_map(value) do
    with :ok <- check_required(schema["required"], value, path) do
      check_properties(schema["properties"], value, path)
    end
  end

  defp check_object(_schema, _value, _path), do: :ok

  defp check_required(required, value, path) when is_list(required) do
    case Enum.find(required, fn key -> not Map.has_key?(value, key) end) do
      nil -> :ok
      missing -> {:error, "#{at(path)}missing required property #{inspect(missing)}"}
    end
  end

  defp check_required(_required, _value, _path), do: :ok

  defp check_properties(properties, value, path) when is_map(properties) do
    Enum.reduce_while(properties, :ok, fn {key, subschema}, :ok ->
      case Map.fetch(value, key) do
        {:ok, sub} ->
          case do_validate(subschema, sub, join(path, key)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp check_properties(_properties, _value, _path), do: :ok

  ## array: items

  defp check_array(%{"type" => "array", "items" => items}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case do_validate(items, element, join(path, index)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_array(_schema, _value, _path), do: :ok

  ## path helpers

  defp join("", key), do: to_string(key)
  defp join(path, key), do: "#{path}.#{key}"

  defp at(""), do: ""
  defp at(path), do: "#{path}: "
end
