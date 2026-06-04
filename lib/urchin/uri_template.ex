defmodule Urchin.URITemplate do
  @moduledoc """
  Minimal RFC 6570 URI template matching used to route `resources/read` requests to
  a declared `resource_template`.

  Supports level-1 `{var}` expressions. A bare `{var}` matches a single path segment
  (no `/`); `{+var}` and `{var*}` match across segments. This is sufficient for the
  common resource-template patterns; full RFC 6570 expansion is intentionally not
  implemented.
  """

  @doc """
  Compiles a URI template into a `{regex, var_names}` pair for repeated matching.
  """
  @spec compile(String.t()) :: {Regex.t(), [String.t()]}
  def compile(template) when is_binary(template) do
    {pattern, vars} = build_pattern(template)
    {Regex.compile!("^" <> pattern <> "$"), vars}
  end

  @doc """
  Matches `uri` against `template`, returning extracted variables on success.

  Accepts either a raw template string or a precompiled `{regex, vars}` tuple.
  """
  @spec match(String.t() | {Regex.t(), [String.t()]}, String.t()) ::
          {:ok, %{String.t() => String.t()}} | :error
  def match(template, uri) when is_binary(template) do
    match(compile(template), uri)
  end

  def match({regex, vars}, uri) when is_binary(uri) do
    case Regex.run(regex, uri, capture: :all_but_first) do
      nil ->
        :error

      captures ->
        decoded = Enum.map(captures, &URI.decode/1)
        {:ok, vars |> Enum.zip(decoded) |> Map.new()}
    end
  end

  # Walks the template, turning literal runs into escaped regex and `{...}`
  # expressions into capture groups.
  defp build_pattern(template) do
    Regex.split(~r/\{[^}]+\}/, template, include_captures: true, trim: false)
    |> Enum.reduce({"", []}, fn segment, {pattern, vars} ->
      case parse_expression(segment) do
        {:var, name, regex_fragment} -> {pattern <> regex_fragment, vars ++ [name]}
        {:literal, literal} -> {pattern <> Regex.escape(literal), vars}
      end
    end)
  end

  defp parse_expression("{" <> rest) do
    inner = String.trim_trailing(rest, "}")

    {name, fragment} =
      cond do
        String.starts_with?(inner, "+") ->
          var = String.trim_leading(inner, "+")
          {var, "(.+)"}

        String.ends_with?(inner, "*") ->
          var = String.trim_trailing(inner, "*")
          {var, "(.+)"}

        true ->
          {inner, "([^/]+)"}
      end

    {:var, name, fragment}
  end

  defp parse_expression(literal), do: {:literal, literal}
end
