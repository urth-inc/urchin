defmodule Urchin.Schema do
  @moduledoc """
  Minimal structural validation of tool arguments against a JSON Schema.

  This is a deliberately small subset of JSON Schema, sufficient to catch the common
  argument mistakes the DSL's `input_schema` describes, without pulling in a full
  validation dependency. It validates `type` (object, array, string, number, integer,
  boolean, null, and union types such as `["string", "null"]`), object `properties`,
  `required` and `additionalProperties: false`, array `items`, and `enum`. Other keywords
  (`minLength`, `pattern`, `format`, ...) are ignored rather than enforced.

  Schema keywords may be keyed by string or atom (so `%{"type" => "object"}` and
  `%{type: "object"}` both validate); the values being validated come from JSON and are
  expected to be string-keyed. For full JSON Schema validation, validate in your handler
  with a dedicated library (e.g. `:ex_json_schema`).
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
    with :ok <- check_type(get(schema, "type"), value, path),
         :ok <- check_enum(get(schema, "enum"), value, path),
         :ok <- check_object(schema, value, path) do
      check_array(schema, value, path)
    end
  end

  # Schema keywords may be string- or atom-keyed.
  defp get(schema, "type"), do: schema["type"] || schema[:type]
  defp get(schema, "enum"), do: schema["enum"] || schema[:enum]
  defp get(schema, "required"), do: schema["required"] || schema[:required]
  defp get(schema, "properties"), do: schema["properties"] || schema[:properties]
  defp get(schema, "items"), do: schema["items"] || schema[:items]

  defp get(schema, "additionalProperties") do
    case Map.fetch(schema, "additionalProperties") do
      {:ok, value} -> value
      :error -> Map.get(schema, :additionalProperties)
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

  # Union types, e.g. `type: ["string", "null"]`: the value must match at least one.
  defp check_type(types, value, path) when is_list(types) do
    if Enum.any?(types, fn type -> check_type(type, value, path) == :ok end),
      do: :ok,
      else: {:error, "#{at(path)}expected one of #{inspect(types)}, got #{inspect(value)}"}
  end

  defp check_type(type, value, path),
    do: {:error, "#{at(path)}expected #{type}, got #{inspect(value)}"}

  ## enum

  defp check_enum(nil, _value, _path), do: :ok

  defp check_enum(allowed, value, path) when is_list(allowed) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{at(path)}value #{inspect(value)} is not one of #{inspect(allowed)}"}
  end

  defp check_enum(_allowed, _value, _path), do: :ok

  ## object: required + properties + additionalProperties

  defp check_object(schema, value, path) when is_map(value) do
    if get(schema, "type") == "object" do
      properties = get(schema, "properties")

      with :ok <- check_required(get(schema, "required"), value, path),
           :ok <- check_properties(properties, value, path) do
        check_additional(get(schema, "additionalProperties"), properties, value, path)
      end
    else
      :ok
    end
  end

  defp check_object(_schema, _value, _path), do: :ok

  defp check_required(required, value, path) when is_list(required) do
    case Enum.find(required, fn key -> not Map.has_key?(value, to_string(key)) end) do
      nil -> :ok
      missing -> {:error, "#{at(path)}missing required property #{inspect(to_string(missing))}"}
    end
  end

  defp check_required(_required, _value, _path), do: :ok

  defp check_properties(properties, value, path) when is_map(properties) do
    Enum.reduce_while(properties, :ok, fn {raw_key, subschema}, :ok ->
      key = to_string(raw_key)

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

  # additionalProperties: false rejects any key not named in properties.
  defp check_additional(false, properties, value, path) do
    allowed = property_names(properties)

    case Enum.find(Map.keys(value), fn key -> to_string(key) not in allowed end) do
      nil -> :ok
      extra -> {:error, "#{at(path)}unexpected property #{inspect(to_string(extra))}"}
    end
  end

  defp check_additional(_additional, _properties, _value, _path), do: :ok

  defp property_names(properties) when is_map(properties),
    do: properties |> Map.keys() |> Enum.map(&to_string/1)

  defp property_names(_properties), do: []

  ## array: items

  defp check_array(schema, value, path) when is_list(value) do
    case get(schema, "type") == "array" && get(schema, "items") do
      false -> :ok
      nil -> :ok
      items -> validate_items(items, value, path)
    end
  end

  defp check_array(_schema, _value, _path), do: :ok

  defp validate_items(items, value, path) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case do_validate(items, element, join(path, index)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  ## path helpers

  defp join("", key), do: to_string(key)
  defp join(path, key), do: "#{path}.#{key}"

  defp at(""), do: ""
  defp at(path), do: "#{path}: "
end
