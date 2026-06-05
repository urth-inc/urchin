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
end
