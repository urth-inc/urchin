defmodule Urchin.SchemaTest do
  use ExUnit.Case, async: true

  alias Urchin.Schema

  test "a nil or non-map schema accepts any value" do
    assert Schema.validate(nil, %{"anything" => true}) == :ok
    assert Schema.validate("not a schema", 42) == :ok
  end

  describe "type checks" do
    test "accepts matching primitive types" do
      assert Schema.validate(%{"type" => "string"}, "x") == :ok
      assert Schema.validate(%{"type" => "integer"}, 1) == :ok
      assert Schema.validate(%{"type" => "number"}, 1.5) == :ok
      assert Schema.validate(%{"type" => "boolean"}, true) == :ok
      assert Schema.validate(%{"type" => "null"}, nil) == :ok
    end

    test "rejects mismatched types with a descriptive message" do
      assert {:error, message} = Schema.validate(%{"type" => "string"}, 1)
      assert message =~ "expected string"
    end

    test "integer is stricter than number" do
      assert {:error, _} = Schema.validate(%{"type" => "integer"}, 1.5)
      assert Schema.validate(%{"type" => "number"}, 1) == :ok
    end
  end

  describe "objects" do
    @schema %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "integer"},
        "b" => %{"type" => "string"}
      },
      "required" => ["a"]
    }

    test "accepts an object satisfying required and property types" do
      assert Schema.validate(@schema, %{"a" => 1, "b" => "ok"}) == :ok
      assert Schema.validate(@schema, %{"a" => 1}) == :ok
    end

    test "reports a missing required property" do
      assert {:error, message} = Schema.validate(@schema, %{"b" => "ok"})
      assert message =~ "required"
      assert message =~ "a"
    end

    test "reports a property whose type is wrong, with its path" do
      assert {:error, message} = Schema.validate(@schema, %{"a" => "nope"})
      assert message =~ "a: expected integer"
    end

    test "validates nested objects recursively" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "outer" => %{"type" => "object", "properties" => %{"inner" => %{"type" => "integer"}}}
        }
      }

      assert {:error, message} = Schema.validate(schema, %{"outer" => %{"inner" => "x"}})
      assert message =~ "outer.inner: expected integer"
    end
  end

  describe "enum and arrays" do
    test "enforces enum membership" do
      schema = %{"enum" => ["a", "b"]}
      assert Schema.validate(schema, "a") == :ok
      assert {:error, message} = Schema.validate(schema, "c")
      assert message =~ "not one of"
    end

    test "validates array items" do
      schema = %{"type" => "array", "items" => %{"type" => "integer"}}
      assert Schema.validate(schema, [1, 2, 3]) == :ok
      assert {:error, message} = Schema.validate(schema, [1, "two"])
      assert message =~ "1: expected integer"
    end
  end
end
