defmodule Urchin.CoreTest do
  use ExUnit.Case, async: true

  alias Urchin.{Capabilities, Content, Error, JSONRPC, Protocol, Tool, URITemplate}

  describe "Urchin.Protocol" do
    test "negotiates supported versions and falls back otherwise" do
      assert Protocol.negotiate("2025-11-25") == "2025-11-25"
      assert Protocol.negotiate("2025-06-18") == "2025-06-18"
      assert Protocol.negotiate("1999-01-01") == Protocol.latest_version()
      assert Protocol.supported?("2025-11-25")
      refute Protocol.supported?("nope")
    end
  end

  describe "Urchin.JSONRPC.decode/1 classification" do
    test "classifies a request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"c"}})
      assert {:ok, {:request, 1, "tools/list", %{"cursor" => "c"}}} = JSONRPC.decode(json)
    end

    test "classifies a notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
      assert {:ok, {:notification, "notifications/initialized", %{}}} = JSONRPC.decode(json)
    end

    test "classifies a result response" do
      json = ~s({"jsonrpc":"2.0","id":"srv-1","result":{"ok":true}})
      assert {:ok, {:response, "srv-1", %{"ok" => true}}} = JSONRPC.decode(json)
    end

    test "classifies an error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}})
      assert {:ok, {:error_response, 1, %{"code" => -32_601}}} = JSONRPC.decode(json)
    end

    test "rejects malformed JSON with a parse error" do
      assert {:error, %Error{code: -32_700}} = JSONRPC.decode("{bad")
    end

    test "rejects batches" do
      assert {:error, %Error{code: -32_600}} = JSONRPC.decode("[]")
    end

    test "rejects a wrong jsonrpc version" do
      assert {:error, %Error{code: -32_600}} =
               JSONRPC.decode(~s({"jsonrpc":"1.0","id":1,"method":"x"}))
    end
  end

  describe "Urchin.JSONRPC builders" do
    test "request omits empty params" do
      assert JSONRPC.request(1, "ping") == %{jsonrpc: "2.0", id: 1, method: "ping"}
    end

    test "notification includes params when given" do
      assert JSONRPC.notification("notifications/progress", %{progress: 1}) ==
               %{jsonrpc: "2.0", method: "notifications/progress", params: %{progress: 1}}
    end

    test "error response carries a null id when unassociated" do
      json = JSONRPC.error_response(nil, Error.parse_error()) |> JSONRPC.encode!()
      assert json =~ ~s("id":null)
      assert json =~ ~s("code":-32700)
    end
  end

  describe "Urchin.Content" do
    test "text block" do
      assert Content.text("hi") == %{type: "text", text: "hi"}
    end

    test "image block with annotations" do
      block = Content.image("AAAA", "image/png", annotations: %{audience: ["user"]})
      assert block.type == "image"
      assert block.mimeType == "image/png"
      assert block.annotations == %{audience: ["user"]}
    end

    test "text resource contents" do
      contents = Content.text_resource("file://x", "data", mime_type: "text/plain")
      assert contents == %{uri: "file://x", text: "data", mimeType: "text/plain"}
    end

    test "resource_link from a map requires :name and normalizes keys" do
      block = Content.resource_link(%{uri: "file://x", name: "x", mime_type: "text/plain"})
      assert block.type == "resource_link"
      assert block.uri == "file://x"
      assert block.name == "x"
      assert block.mimeType == "text/plain"
      refute Map.has_key?(block, :mime_type)

      assert_raise ArgumentError, fn -> Content.resource_link(%{uri: "file://x"}) end
    end
  end

  describe "Urchin.Capabilities.server/1" do
    test "advertises only enabled groups" do
      caps =
        Capabilities.server(%{
          tools: %{list_changed: true},
          resources: %{subscribe: true, list_changed: false},
          logging: true
        })

      assert caps == %{tools: %{listChanged: true}, resources: %{subscribe: true}, logging: %{}}
    end

    test "empty flags yields empty capabilities" do
      assert Capabilities.server(%{}) == %{}
    end
  end

  describe "Urchin.Tool JSON encoding" do
    test "drops nil fields and defaults the input schema" do
      tool = Tool.new(name: "t", description: "d")
      decoded = tool |> Jason.encode!() |> Jason.decode!()

      assert decoded == %{
               "name" => "t",
               "description" => "d",
               "inputSchema" => %{"type" => "object", "additionalProperties" => false}
             }
    end
  end

  describe "Urchin.Tool schema validation" do
    test "accepts an object input and output schema" do
      tool =
        Tool.new(
          name: "t",
          input_schema: %{"type" => "object", "properties" => %{}},
          output_schema: %{"type" => "object"}
        )

      assert tool.input_schema["type"] == "object"
      assert tool.output_schema["type"] == "object"
    end

    test "rejects an input schema whose root type is not object" do
      assert_raise ArgumentError, ~r/input_schema.*type.*object/, fn ->
        Tool.new(name: "t", input_schema: %{"type" => "array"})
      end
    end

    test "rejects a non-map input schema" do
      assert_raise ArgumentError, ~r/input_schema must be a map/, fn ->
        Tool.new(name: "t", input_schema: "nope")
      end
    end

    test "rejects an output schema whose root type is not object" do
      assert_raise ArgumentError, ~r/output_schema.*type.*object/, fn ->
        Tool.new(name: "t", output_schema: %{"type" => "string"})
      end
    end
  end

  describe "Urchin.URITemplate" do
    test "matches a single-segment variable" do
      assert {:ok, %{"name" => "world"}} =
               URITemplate.match("greeting://{name}", "greeting://world")
    end

    test "does not match across segments for a bare variable" do
      assert :error = URITemplate.match("files://{name}", "files://a/b")
    end

    test "matches across segments for a reserved expansion" do
      assert {:ok, %{"path" => "a/b/c"}} = URITemplate.match("files://{+path}", "files://a/b/c")
    end

    test "decodes percent-encoded values" do
      assert {:ok, %{"name" => "a b"}} =
               URITemplate.match("greeting://{name}", "greeting://a%20b")
    end
  end

  describe "Urchin.Error" do
    test "wrap passes through MCP errors and wraps others" do
      err = Error.invalid_params("bad")
      assert Error.wrap(err) == err
      assert %Error{code: -32_603} = Error.wrap(:boom)
    end

    test "to_map omits nil data" do
      assert Error.to_map(Error.new(-1, "m")) == %{code: -1, message: "m"}
      assert Error.to_map(Error.new(-1, "m", %{x: 1})) == %{code: -1, message: "m", data: %{x: 1}}
    end
  end
end
