defmodule Urchin.ServerTest do
  use ExUnit.Case, async: true

  describe "tool :scopes validation" do
    test "rejects a non-list literal :scopes at compile time" do
      source = """
      defmodule Urchin.ServerTest.BadScopes do
        use Urchin.Server, name: "bad", version: "1.0.0"

        tool "x", scopes: "files:write" do
          {:ok, [Urchin.Content.text("ok")]}
        end
      end
      """

      assert_raise ArgumentError, ~r/:scopes must be a list/, fn ->
        Code.compile_string(source)
      end
    end

    test "accepts a list of scopes" do
      source = """
      defmodule Urchin.ServerTest.GoodScopes do
        use Urchin.Server, name: "good", version: "1.0.0"

        tool "x", scopes: ["files:write"] do
          {:ok, [Urchin.Content.text("ok")]}
        end
      end
      """

      assert [{Urchin.ServerTest.GoodScopes, _}] = Code.compile_string(source)
    end
  end

  describe "tool name validation" do
    test "does not enforce a tool-name pattern (the MCP schema imposes none)" do
      source = """
      defmodule Urchin.ServerTest.UnusualName do
        use Urchin.Server, name: "unusual", version: "1.0.0"

        tool "bad name!" do
          {:ok, [Urchin.Content.text("ok")]}
        end
      end
      """

      assert [{Urchin.ServerTest.UnusualName, _} | _] = Code.compile_string(source)
    end

    test "rejects duplicate tool names at compile time (always on)" do
      source = """
      defmodule Urchin.ServerTest.DupNames do
        use Urchin.Server, name: "dup", version: "1.0.0"

        tool "dup" do
          {:ok, [Urchin.Content.text("a")]}
        end

        tool "dup" do
          {:ok, [Urchin.Content.text("b")]}
        end
      end
      """

      assert_raise ArgumentError, ~r/duplicate tool name/, fn ->
        Code.compile_string(source)
      end
    end

    test "accepts valid, unique names" do
      source = """
      defmodule Urchin.ServerTest.GoodNames do
        use Urchin.Server, name: "good-names", version: "1.0.0"

        tool "echo" do
          {:ok, [Urchin.Content.text("a")]}
        end

        tool "my.tool-1" do
          {:ok, [Urchin.Content.text("b")]}
        end
      end
      """

      assert [{Urchin.ServerTest.GoodNames, _} | _] = Code.compile_string(source)
    end
  end
end
