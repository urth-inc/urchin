defmodule Urchin.DispatcherTest.LoggingServer do
  @moduledoc false
  # Exports set_log_level/2 so the builtin-plus-hook path can be exercised.
  use Urchin.Server, name: "logging", version: "1.0.0", logging: true

  @impl true
  def set_log_level(level, ctx) do
    case ctx.assigns do
      %{test_pid: pid} -> send(pid, {:set_log_level_called, level})
      _ -> :ok
    end

    :ok
  end
end

defmodule Urchin.DispatcherTest.NoLoggingServer do
  @moduledoc false
  # Advertises no logging capability.
  use Urchin.Server, name: "no-logging", version: "1.0.0"
end

defmodule Urchin.DispatcherTest.FailingLoggingServer do
  @moduledoc false
  # Advertises logging (via the callback) but the set_log_level/2 hook always fails.
  use Urchin.Server, name: "failing-logging", version: "1.0.0"

  @impl true
  def set_log_level(_level, _ctx), do: {:error, "nope"}
end

defmodule Urchin.DispatcherTest.BadInfoServer do
  @moduledoc false
  # A hand-written server whose server_info/0 omits the required version field.
  @behaviour Urchin.Server

  @impl true
  def server_info, do: %{name: "bad"}

  @impl true
  def capabilities, do: %{}
end

defmodule Urchin.DispatcherTest.BigCompletionServer do
  @moduledoc false
  # Returns more than the 100-value completion cap so truncation can be exercised.
  use Urchin.Server, name: "big-completion", version: "1.0.0", completions: true

  @impl true
  def complete(_ref, _argument, _context, _ctx) do
    {:ok, %{values: Enum.map(1..150, &"v#{&1}")}}
  end
end

defmodule Urchin.DispatcherTest.BadCompletionServer do
  @moduledoc false
  # Returns a non-conforming completion result (values are not strings).
  use Urchin.Server, name: "bad-completion", version: "1.0.0", completions: true

  @impl true
  def complete(_ref, _argument, _context, _ctx) do
    {:ok, %{values: [1, 2, 3]}}
  end
end

defmodule Urchin.DispatcherTest do
  use ExUnit.Case, async: true

  alias Urchin.{Context, Dispatcher, Session}
  alias Urchin.Test.EchoServer
  alias Urchin.DispatcherTest.{LoggingServer, NoLoggingServer, FailingLoggingServer}
  alias Urchin.DispatcherTest.{BadInfoServer, BigCompletionServer, BadCompletionServer}

  # The default context represents an initialized session; the lifecycle gate is exercised
  # explicitly in the "initialized gating" describe with initialized: false.
  defp ctx, do: %Context{initialized: true}

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
      params = %{
        "protocolVersion" => "1999-01-01",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "c", "version" => "1"}
      }

      assert {:ok, result, _meta} = Dispatcher.initialize(EchoServer, params, ctx())
      assert result.protocolVersion == Urchin.protocol_version()
    end

    test "rejects a missing protocolVersion" do
      params = %{"capabilities" => %{}, "clientInfo" => %{"name" => "c", "version" => "1"}}
      assert {:error, error} = Dispatcher.initialize(EchoServer, params, ctx())
      assert error.code == -32_602
    end

    test "rejects a missing capabilities object" do
      params = %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "c", "version" => "1"}
      }

      assert {:error, error} = Dispatcher.initialize(EchoServer, params, ctx())
      assert error.code == -32_602
    end

    test "rejects clientInfo without a string name and version" do
      params = %{"protocolVersion" => "2025-11-25", "capabilities" => %{}, "clientInfo" => %{}}
      assert {:error, error} = Dispatcher.initialize(EchoServer, params, ctx())
      assert error.code == -32_602
    end

    test "rejects a serverInfo missing name or version" do
      params = %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "c", "version" => "1"}
      }

      assert {:error, error} = Dispatcher.initialize(BadInfoServer, params, ctx())
      assert error.code == -32_603
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

    test "a raising tool redacts its exception message by default" do
      params = %{"name" => "boom", "arguments" => %{}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result.content == [%{type: "text", text: "Tool execution failed"}]
      refute result.content |> hd() |> Map.get(:text) =~ "kaboom"
    end

    test "a raising tool exposes its message when expose_internal_errors is set" do
      params = %{"name" => "boom", "arguments" => %{}}
      ctx = %Context{expose_internal_errors: true, initialized: true}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx)
      assert result.content == [%{type: "text", text: "kaboom"}]
    end

    test "unknown tool is an invalid params error" do
      params = %{"name" => "nope", "arguments" => %{}}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.code == -32_602
    end

    test "a non-binary handler error reason is redacted by default" do
      params = %{"name" => "leaky", "arguments" => %{}}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.message == "Internal server error"
      refute error.message =~ "secret"
    end

    test "a non-binary handler error reason is exposed when configured" do
      params = %{"name" => "leaky", "arguments" => %{}}
      ctx = %Context{expose_internal_errors: true, initialized: true}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx)
      assert error.message =~ "postgres"
    end
  end

  describe "declarative tool scopes" do
    alias Urchin.Auth.Claims

    defp call_secret(ctx) do
      Dispatcher.handle_request(
        EchoServer,
        "tools/call",
        %{"name" => "secret", "arguments" => %{}},
        ctx
      )
    end

    test "runs the handler when the required scope is granted" do
      ctx = %Context{auth: %Claims{scopes: ["secret:read"]}, initialized: true}

      assert {:ok, %{content: [%{type: "text", text: "classified"}], isError: false}} =
               call_secret(ctx)

      # The handler signals execution via a message to the (inline) test process.
      assert_received :secret_executed
    end

    test "denies when the granted scopes are insufficient" do
      assert {:error, error} =
               call_secret(%Context{auth: %Claims{scopes: ["other"]}, initialized: true})

      assert error.message =~ "scope"
    end

    test "denies (fail closed) when the request carries no authorization" do
      assert {:error, error} = call_secret(%Context{auth: nil, initialized: true})
      assert error.message =~ "scope"
    end

    test "a denied call never executes the handler" do
      assert {:error, _} =
               call_secret(%Context{auth: %Claims{scopes: ["other"]}, initialized: true})

      refute_received :secret_executed
    end

    test "scope denial has a stable error code and the required scopes in data" do
      assert {:error, error} = call_secret(%Context{auth: %Claims{scopes: []}, initialized: true})
      assert error.code == -32_600
      assert error.data == %{required_scopes: ["secret:read"]}
    end
  end

  describe "argument validation" do
    test "an input-schema violation is an isError tool result" do
      params = %{"name" => "add", "arguments" => %{"a" => 1}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      assert text =~ "b"
    end

    test "accepts valid arguments" do
      params = %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2}}

      assert {:ok, %{structuredContent: %{"sum" => 3}}} =
               Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
    end

    test "a tool that declares no schema rejects unexpected properties" do
      # An omitted input_schema defaults to an object accepting no properties.
      params = %{"name" => "no_schema", "arguments" => %{"extra" => 1}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result.isError == true
    end

    test "non-object arguments are a protocol error, not a tool input error" do
      # CallToolRequestParams.arguments is, when present, an object. A non-object value violates the
      # request shape, so it stays a JSON-RPC error rather than an isError tool result.
      params = %{"name" => "no_schema", "arguments" => "not-an-object"}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.code == -32_602
    end

    test "array arguments are rejected as a protocol error" do
      params = %{"name" => "no_schema", "arguments" => ["not", "an", "object"]}
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

    test "caps completion values at 100 and forces hasMore when truncated" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "x"},
        "argument" => %{"name" => "n", "value" => "v"}
      }

      assert {:ok, %{completion: completion}} =
               Dispatcher.handle_request(
                 BigCompletionServer,
                 "completion/complete",
                 params,
                 ctx()
               )

      assert length(completion.values) == 100
      assert completion.hasMore == true
    end

    test "rejects an argument without a string name and value" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "greet"},
        "argument" => %{"name" => "name"}
      }

      assert {:error, error} =
               Dispatcher.handle_request(EchoServer, "completion/complete", params, ctx())

      assert error.code == -32_602
    end

    test "rejects an unknown ref type" do
      params = %{
        "ref" => %{"type" => "ref/bogus"},
        "argument" => %{"name" => "name", "value" => "Sa"}
      }

      assert {:error, error} =
               Dispatcher.handle_request(EchoServer, "completion/complete", params, ctx())

      assert error.code == -32_602
    end

    test "rejects non-string context.arguments values" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "greet"},
        "argument" => %{"name" => "name", "value" => "Sa"},
        "context" => %{"arguments" => %{"prior" => 1}}
      }

      assert {:error, error} =
               Dispatcher.handle_request(EchoServer, "completion/complete", params, ctx())

      assert error.code == -32_602
    end

    test "a non-conforming completion result is an internal error" do
      params = %{
        "ref" => %{"type" => "ref/prompt", "name" => "x"},
        "argument" => %{"name" => "n", "value" => "v"}
      }

      assert {:error, error} =
               Dispatcher.handle_request(
                 BadCompletionServer,
                 "completion/complete",
                 params,
                 ctx()
               )

      assert error.code == -32_603
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

  describe "logging/setLevel" do
    test "succeeds as a builtin without a server callback" do
      assert {:ok, %{}} =
               Dispatcher.handle_request(
                 EchoServer,
                 "logging/setLevel",
                 %{"level" => "warning"},
                 ctx()
               )
    end

    test "rejects a missing level param" do
      assert {:error, error} =
               Dispatcher.handle_request(EchoServer, "logging/setLevel", %{}, ctx())

      assert error.code == -32_602
    end

    test "reflects the requested level on the session" do
      {:ok, _id, pid} = Session.start(server: EchoServer, protocol_version: "2025-11-25")
      on_exit(fn -> Session.terminate(pid) end)

      assert {:ok, %{}} =
               Dispatcher.handle_request(
                 EchoServer,
                 "logging/setLevel",
                 %{"level" => "error"},
                 %Context{session: pid, initialized: true}
               )

      assert Session.snapshot(pid).min_log_level == "error"
    end

    test "invokes an exported set_log_level/2 hook" do
      ctx = %Context{assigns: %{test_pid: self()}, initialized: true}

      assert {:ok, %{}} =
               Dispatcher.handle_request(
                 LoggingServer,
                 "logging/setLevel",
                 %{"level" => "info"},
                 ctx
               )

      assert_received {:set_log_level_called, "info"}
    end

    test "rejects an invalid level with -32602 and leaves the session unchanged" do
      {:ok, _id, pid} = Session.start(server: EchoServer, protocol_version: "2025-11-25")
      on_exit(fn -> Session.terminate(pid) end)

      assert {:error, error} =
               Dispatcher.handle_request(
                 EchoServer,
                 "logging/setLevel",
                 %{"level" => "verbose"},
                 %Context{session: pid, initialized: true}
               )

      assert error.code == -32_602
      assert Session.snapshot(pid).min_log_level != "verbose"
    end

    test "is not available unless the server advertises the logging capability" do
      assert {:error, error} =
               Dispatcher.handle_request(
                 NoLoggingServer,
                 "logging/setLevel",
                 %{"level" => "info"},
                 ctx()
               )

      assert error.code == -32_601
    end

    test "leaves the session unchanged when the set_log_level/2 hook fails" do
      {:ok, _id, pid} =
        Session.start(server: FailingLoggingServer, protocol_version: "2025-11-25")

      on_exit(fn -> Session.terminate(pid) end)
      before = Session.snapshot(pid).min_log_level

      assert {:error, _error} =
               Dispatcher.handle_request(
                 FailingLoggingServer,
                 "logging/setLevel",
                 %{"level" => "warning"},
                 %Context{session: pid, initialized: true}
               )

      assert Session.snapshot(pid).min_log_level == before
    end
  end

  describe "initialized gating" do
    test "rejects operation requests before initialized" do
      ctx = %Context{initialized: false}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/list", %{}, ctx)
      assert error.code == -32_600
    end

    test "allows ping before initialized" do
      ctx = %Context{initialized: false}
      assert {:ok, %{}} = Dispatcher.handle_request(EchoServer, "ping", %{}, ctx)
    end

    test "rejects logging/setLevel before initialized (only ping is exempt)" do
      # The lifecycle's pre-init exception for logging is the server's own requests, not the
      # client's logging/setLevel, so it is gated like any other operation request.
      ctx = %Context{initialized: false}

      assert {:error, error} =
               Dispatcher.handle_request(
                 EchoServer,
                 "logging/setLevel",
                 %{"level" => "info"},
                 ctx
               )

      assert error.code == -32_600
    end

    test "allows operation requests once initialized" do
      ctx = %Context{initialized: true}
      assert {:ok, %{tools: _}} = Dispatcher.handle_request(EchoServer, "tools/list", %{}, ctx)
    end
  end

  describe "tool errors" do
    test "a binary tool error becomes an isError result" do
      params = %{"name" => "failing", "arguments" => %{}}
      assert {:ok, result} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert result == %{content: [%{type: "text", text: "tool said no"}], isError: true}
    end

    test "a protocol error is still surfaced as a JSON-RPC error" do
      params = %{"name" => "protocol_error", "arguments" => %{}}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.code == -32_602
    end

    test "a raised Urchin.Error is a JSON-RPC error, not an isError result" do
      params = %{"name" => "raise_protocol", "arguments" => %{}}
      assert {:error, error} = Dispatcher.handle_request(EchoServer, "tools/call", params, ctx())
      assert error.code == -32_602
      assert error.message == "raised bad"
    end
  end
end
