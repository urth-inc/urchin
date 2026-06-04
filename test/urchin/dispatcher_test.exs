defmodule Urchin.DispatcherTest do
  use ExUnit.Case, async: true

  alias Urchin.{Context, Dispatcher}
  alias Urchin.Test.EchoServer

  defp ctx, do: %Context{}

  describe "initialize/3" do
    test "negotiates a supported version and reports capabilities" do
      params = %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "c", "version" => "1"}
      }

      assert {:ok, result, meta} = Dispatcher.initialize(EchoServer, params, ctx())
      assert result.protocolVersion == "2025-11-25"
      assert result.serverInfo == %{name: "echo-server", version: "1.0.0"}
      assert result.instructions == "A test server."

      assert %{tools: %{}, prompts: %{}, resources: %{}, logging: %{}, completions: %{}} =
               result.capabilities

      assert meta.protocol_version == "2025-11-25"
    end

    test "falls back to latest for an unsupported version" do
      params = %{"protocolVersion" => "1999-01-01", "capabilities" => %{}}
      assert {:ok, result, _meta} = Dispatcher.initialize(EchoServer, params, ctx())
      assert result.protocolVersion == Urchin.protocol_version()
    end
  end

  describe "tools" do
    test "tools/list returns declared tools" do
      assert {:ok, %{tools: tools}} =
               Dispatcher.handle_request(EchoServer, "tools/list", %{}, ctx())

      names = Enum.map(tools, & &1.name)
      assert "echo" in names
      assert "add" in names
    end

    test "tools/call echoes" do
      params = %{"name" => "echo", "arguments" => %{"message" => "hi"}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result == %{content: [%{type: "text", text: "hi"}], isError: false}
    end

    test "tools/call with structured content" do
      params = %{"name" => "add", "arguments" => %{"a" => 2, "b" => 3}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result.structuredContent == %{"sum" => 5}
      assert result.isError == false
    end

    test "a raising tool becomes an isError result" do
      params = %{"name" => "boom", "arguments" => %{}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result.isError == true
      assert [%{type: "text"}] = result.content
    end

    test "unknown tool is an invalid params error" do
      params = %{"name" => "nope", "arguments" => %{}}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.code == -32_602
    end
  end

  describe "resources" do
    test "resources/list and read of a static resource" do
      assert {:ok, %{resources: [resource]}} =
               Dispatcher.handle_request(EchoServer, "resources/list", %{}, ctx())

      assert resource.uri == "config://app"

      assert {:ok, %{contents: [contents]}} =
               Dispatcher.handle_request(
                 EchoServer,
                 "resources/read",
                 %{"uri" => "config://app"},
                 ctx()
               )

      assert contents.uri == "config://app"
      assert contents.text == ~s({"ok":true})
    end

    test "resources/read matches a template and extracts params" do
      assert {:ok, %{contents: [contents]}} =
               Dispatcher.handle_request(
                 EchoServer,
                 "resources/read",
                 %{"uri" => "greeting://world"},
                 ctx()
               )

      assert contents.text == "Hello, world"
    end

    test "resources/templates/list returns the template" do
      assert {:ok, %{resourceTemplates: [template]}} =
               Dispatcher.handle_request(EchoServer, "resources/templates/list", %{}, ctx())

      assert template.uri_template == "greeting://{name}"
    end

    test "unknown resource yields resource-not-found" do
      assert {:error, error} =
               Dispatcher.handle_request(EchoServer, "resources/read", %{"uri" => "x://y"}, ctx())

      assert error.code == -32_002
    end
  end

  describe "prompts" do
    test "prompts/list and get" do
      assert {:ok, %{prompts: [prompt]}} =
               Dispatcher.handle_request(EchoServer, "prompts/list", %{}, ctx())

      assert prompt.name == "greet"

      params = %{"name" => "greet", "arguments" => %{"name" => "Sam"}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "prompts/get", params, ctx())
      assert result.description == "A greeting"
      assert [%{role: "user", content: %{type: "text", text: "Hello Sam"}}] = result.messages
    end
  end

  describe "completion and ping" do
    test "completion/complete" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "greet"},
        "argument" => %{"name" => "name", "value" => "Sa"}
      }

      assert {:ok, %{completion: completion}} =
               Dispatcher.handle_request(EchoServer, "completion/complete", params, ctx())

      assert completion.values == ["Sa-1", "Sa-2"]
      assert completion.hasMore == false
    end

    test "ping" do
      assert {:ok, %{}} = Dispatcher.handle_request(EchoServer, "ping", %{}, ctx())
    end

    test "unknown method" do
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "no/such", %{}, ctx())
      assert error.code == -32_601
    end

    test "positional (array) params are rejected with -32602" do
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/list", [1, 2], ctx())
      assert error.code == -32_602
    end
  end
end
