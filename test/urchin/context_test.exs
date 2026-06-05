defmodule Urchin.ContextTest do
  use ExUnit.Case, async: true

  alias Urchin.Context
  alias Urchin.Error

  describe "server-initiated request capability guards" do
    test "create_message errors when the client did not advertise sampling" do
      assert {:error, %Error{message: message}} =
               Context.create_message(%Context{client_capabilities: %{}}, %{})

      assert message =~ "sampling"
    end

    test "elicit errors when the client did not advertise elicitation" do
      assert {:error, %Error{message: message}} =
               Context.elicit(%Context{client_capabilities: %{}}, %{})

      assert message =~ "elicitation"
    end

    test "list_roots errors when the client did not advertise roots" do
      assert {:error, %Error{message: message}} =
               Context.list_roots(%Context{client_capabilities: %{}})

      assert message =~ "roots"
    end

    test "a request proceeds past the guard once the capability is advertised" do
      # Capability present but no session: the guard passes and request/4 then reports the
      # missing session, proving the guard did not short-circuit.
      ctx = %Context{client_capabilities: %{"sampling" => %{}}, session: nil}
      assert {:error, %Error{message: message}} = Context.create_message(ctx, %{})
      assert message =~ "session"
    end

    test "elicit proceeds past the guard once elicitation is advertised" do
      ctx = %Context{client_capabilities: %{"elicitation" => %{}}, session: nil}
      assert {:error, %Error{message: message}} = Context.elicit(ctx, %{})
      assert message =~ "session"
    end

    test "list_roots proceeds past the guard once roots is advertised" do
      ctx = %Context{client_capabilities: %{"roots" => %{}}, session: nil}
      assert {:error, %Error{message: message}} = Context.list_roots(ctx)
      assert message =~ "session"
    end
  end
end
