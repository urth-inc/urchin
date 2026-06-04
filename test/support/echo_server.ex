defmodule Urchin.Test.EchoServer do
  @moduledoc false
  # A small server exercising the DSL across tools, resources, templates and prompts.

  use Urchin.Server,
    name: "echo-server",
    version: "1.0.0",
    instructions: "A test server.",
    logging: true,
    completions: true

  tool "echo",
    description: "Echo the message back",
    input_schema: %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string"}},
      "required" => ["message"]
    } do
    {:ok, [Urchin.Content.text(args["message"])]}
  end

  tool "add",
    description: "Add two integers",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "integer"},
        "b" => %{"type" => "integer"}
      },
      "required" => ["a", "b"]
    },
    output_schema: %{
      "type" => "object",
      "properties" => %{"sum" => %{"type" => "integer"}}
    } do
    sum = args["a"] + args["b"]
    {:ok, [Urchin.Content.text(Integer.to_string(sum))], structured_content: %{"sum" => sum}}
  end

  tool "boom", description: "Always raises" do
    _ = ctx
    raise "kaboom"
  end

  tool "whoami", description: "Reports the authenticated subject and scopes from ctx.auth" do
    _ = args

    text =
      case Urchin.Context.auth(ctx) do
        nil ->
          "anonymous"

        %Urchin.Auth.Claims{subject: subject, scopes: scopes} ->
          "#{subject}:#{Enum.join(scopes, ",")}"
      end

    {:ok, [Urchin.Content.text(text)]}
  end

  tool "progressive", description: "Emits a progress notification, then a result" do
    _ = args
    Urchin.Context.progress(ctx, 50, total: 100, message: "halfway")
    {:ok, [Urchin.Content.text("done")]}
  end

  tool "ask", description: "Elicits a value from the client, then echoes it" do
    _ = args

    case Urchin.Context.elicit(ctx, %{
           message: "Your name?",
           requestedSchema: %{
             "type" => "object",
             "properties" => %{"name" => %{"type" => "string"}}
           }
         }) do
      {:ok, %{"action" => "accept", "content" => %{"name" => name}}} ->
        {:ok, [Urchin.Content.text("Hello " <> name)]}

      {:ok, _other} ->
        {:ok, [Urchin.Content.text("declined")]}

      {:error, error} ->
        {:error, error}
    end
  end

  resource "config://app",
    name: "app-config",
    mime_type: "application/json" do
    {:ok, [Urchin.Content.text_resource(ctx.uri, ~s({"ok":true}), mime_type: "application/json")]}
  end

  resource_template "greeting://{name}",
    name: "greeting",
    description: "A templated greeting" do
    {:ok, [Urchin.Content.text_resource(ctx.uri, "Hello, " <> ctx.params["name"])]}
  end

  prompt "greet",
    description: "Greeting prompt",
    arguments: [%{name: "name", required: true}] do
    {:ok, [Urchin.Prompt.user_message(Urchin.Content.text("Hello " <> args["name"]))],
     "A greeting"}
  end

  @impl true
  def complete(_ref, %{"value" => value}, _context, _ctx) do
    {:ok, %{values: ["#{value}-1", "#{value}-2"], has_more: false}}
  end
end
