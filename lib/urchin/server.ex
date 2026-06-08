defmodule Urchin.Server do
  @moduledoc """
  Behaviour and DSL for authoring MCP servers.

  There are two ways to define a server:

  ## DSL

      defmodule Demo do
        use Urchin.Server, name: "demo", version: "1.0.0"

        tool "echo",
          description: "Echo the message back",
          input_schema: %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "string"}},
            "required" => ["message"]
          } do
          {:ok, [Urchin.Content.text(args["message"])]}
        end

        resource "config://app", name: "config", mime_type: "application/json" do
          {:ok, [Urchin.Content.text_resource("config://app", ~s({"ok":true}))]}
        end

        prompt "greet", arguments: [%{name: "name", required: true}] do
          {:ok, [Urchin.Prompt.user_message(Urchin.Content.text("Hello " <> args["name"]))]}
        end
      end

  Inside a `tool`/`prompt` block the bindings `args` (the decoded arguments map) and
  `ctx` (an `Urchin.Context`) are available. Inside a `resource`/`resource_template`
  block only `ctx` is available; for templates `ctx.uri` and `ctx.params` are set.

  Capabilities are derived automatically from the declared features.

  Duplicate literal tool names declared via the DSL are rejected at compile time (non-literal
  names cannot be compared statically and are not checked). Urchin enforces no tool-name pattern
  (the MCP schema imposes none); servers should still follow the MCP naming recommendations (a
  conservative charset, a length bound, no whitespace).

  ## Behaviour

  Implement the callbacks directly for full control or stateful servers. All
  callbacks except `c:server_info/0` are optional; a feature is considered supported
  only when its callbacks are implemented (or declared via the DSL).

  ## Handler return values

    * `list_*` callbacks: `{:ok, items}` or `{:ok, items, next_cursor}`
    * `call_tool/3`: `{:ok, content}`, `{:ok, content, opts}` (with `:structured_content`
      / `:is_error`), an `Urchin.Result.CallTool` struct, or `{:error, reason}`
    * `read_resource/2`: `{:ok, contents}` or `{:error, reason}`
    * `get_prompt/3`: `{:ok, messages}` or `{:ok, messages, description}`

  For every callback, a returned or raised `Urchin.Error` becomes that JSON-RPC error. A
  `call_tool/3` handler's `{:error, binary}` is surfaced as a `CallToolResult` with `isError: true`
  so the model can self-correct, as is a tool that raises any other exception. For the other
  callbacks an `{:error, binary}` becomes a JSON-RPC internal error and any other raised exception
  becomes an internal error.
  """

  alias Urchin.{Context, Error}

  @type cursor :: String.t() | nil
  @type list_result(item) ::
          {:ok, [item]} | {:ok, [item], cursor()} | {:error, Error.t() | String.t()}
  @type call_result ::
          {:ok, [map()]}
          | {:ok, [map()], keyword()}
          | {:ok, Urchin.Result.CallTool.t()}
          | {:error, Error.t() | String.t()}

  @callback server_info() :: map()
  @callback instructions() :: String.t() | nil
  @callback capabilities() :: map()
  @callback init(arg :: term()) :: {:ok, term()} | {:error, term()}

  @callback list_tools(cursor(), Context.t()) :: list_result(Urchin.Tool.t())
  @callback call_tool(name :: String.t(), args :: map(), Context.t()) :: call_result()

  @callback list_resources(cursor(), Context.t()) :: list_result(Urchin.Resource.t())
  @callback list_resource_templates(cursor(), Context.t()) ::
              list_result(Urchin.ResourceTemplate.t())
  @callback read_resource(uri :: String.t(), Context.t()) ::
              {:ok, [map()]} | {:error, Error.t() | String.t()}
  @callback subscribe_resource(uri :: String.t(), Context.t()) :: :ok | {:error, term()}
  @callback unsubscribe_resource(uri :: String.t(), Context.t()) :: :ok | {:error, term()}

  @callback list_prompts(cursor(), Context.t()) :: list_result(Urchin.Prompt.t())
  @callback get_prompt(name :: String.t(), args :: map(), Context.t()) ::
              {:ok, [map()]} | {:ok, [map()], String.t() | nil} | {:error, Error.t() | String.t()}

  @callback complete(
              ref :: map(),
              argument :: map(),
              completion_context :: map(),
              Context.t()
            ) :: {:ok, map()} | {:error, Error.t() | String.t()}

  @callback set_log_level(level :: String.t(), Context.t()) :: :ok | {:error, term()}

  @optional_callbacks [
    instructions: 0,
    capabilities: 0,
    init: 1,
    list_tools: 2,
    call_tool: 3,
    list_resources: 2,
    list_resource_templates: 2,
    read_resource: 2,
    subscribe_resource: 2,
    unsubscribe_resource: 2,
    list_prompts: 2,
    get_prompt: 3,
    complete: 4,
    set_log_level: 2
  ]

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Urchin.Server

      import Urchin.Server,
        only: [
          tool: 2,
          tool: 3,
          resource: 2,
          resource: 3,
          resource_template: 2,
          resource_template: 3,
          prompt: 2,
          prompt: 3
        ]

      Module.register_attribute(__MODULE__, :mcp_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_tool_dispatch, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_resource_dispatch, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_resource_templates, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_template_dispatch, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_prompt_dispatch, accumulate: true)

      @mcp_opts unquote(opts)
      @before_compile Urchin.Server

      @impl true
      def server_info, do: Urchin.Server.__server_info__(@mcp_opts)

      @impl true
      def instructions, do: Keyword.get(@mcp_opts, :instructions)

      @impl true
      def init(_arg), do: {:ok, nil}

      defoverridable server_info: 0, instructions: 0, init: 1
    end
  end

  ## DSL macros

  @doc """
  Declares a tool. The `do` block receives `args` and `ctx` bindings and must return
  a `call_tool/3` result.

  Options beyond the `Urchin.Tool` fields:

    * `:scopes` - OAuth scopes the caller must hold (checked against `ctx.auth`) before
      the handler runs. The call fails with an error when the scopes are missing, including
      when the request carries no authorization.
  """
  defmacro tool(name, opts \\ [], do: block) do
    fname = handler_name("tool", name)
    {scopes, tool_opts} = Keyword.pop(opts, :scopes, [])
    scopes = validate_scopes!(scopes)

    quote do
      @mcp_tools Urchin.Tool.new([{:name, unquote(name)} | unquote(tool_opts)])
      @mcp_tool_dispatch {unquote(name), unquote(fname), unquote(scopes)}
      @doc false
      def unquote(fname)(var!(args), var!(ctx)) do
        _ = {var!(args), var!(ctx)}
        unquote(block)
      end
    end
  end

  @doc """
  Declares a static resource. The `do` block receives `ctx` (with `ctx.uri` set) and
  must return a `read_resource/2` result. Defaults `:name` to the URI.
  """
  defmacro resource(uri, opts \\ [], do: block) do
    opts = Keyword.put_new(opts, :name, uri)
    fname = handler_name("resource", uri)

    quote do
      @mcp_resources Urchin.Resource.new([{:uri, unquote(uri)} | unquote(opts)])
      @mcp_resource_dispatch {unquote(uri), unquote(fname)}
      @doc false
      def unquote(fname)(var!(ctx)) do
        _ = var!(ctx)
        unquote(block)
      end
    end
  end

  @doc """
  Declares a resource template (RFC 6570). The `do` block receives `ctx` with
  `ctx.uri` and `ctx.params` (extracted template variables). Defaults `:name` to the
  template.
  """
  defmacro resource_template(uri_template, opts \\ [], do: block) do
    opts = Keyword.put_new(opts, :name, uri_template)
    fname = handler_name("template", uri_template)

    quote do
      @mcp_resource_templates Urchin.ResourceTemplate.new([
                                {:uri_template, unquote(uri_template)} | unquote(opts)
                              ])
      @mcp_template_dispatch {unquote(uri_template), unquote(fname)}
      @doc false
      def unquote(fname)(var!(ctx)) do
        _ = var!(ctx)
        unquote(block)
      end
    end
  end

  @doc """
  Declares a prompt. The `do` block receives `args` and `ctx` bindings and must return
  a `get_prompt/3` result.
  """
  defmacro prompt(name, opts \\ [], do: block) do
    fname = handler_name("prompt", name)

    quote do
      @mcp_prompts Urchin.Prompt.new([{:name, unquote(name)} | unquote(opts)])
      @mcp_prompt_dispatch {unquote(name), unquote(fname)}
      @doc false
      def unquote(fname)(var!(args), var!(ctx)) do
        _ = {var!(args), var!(ctx)}
        unquote(block)
      end
    end
  end

  # Fails the compile on a clearly-wrong literal :scopes (e.g. a bare string). A non-literal
  # expression (a variable or call) is a tuple here and is deferred to runtime.
  defp validate_scopes!(scopes) when is_list(scopes), do: scopes
  defp validate_scopes!(scopes) when is_tuple(scopes), do: scopes

  defp validate_scopes!(other) do
    raise ArgumentError, "tool :scopes must be a list of strings, got: #{inspect(other)}"
  end

  # Duplicate tool names within a server are rejected at compile time (a silently shadowed
  # duplicate is a bug). The MCP schema imposes no tool-name pattern, so none is enforced.
  # Non-literal names (a variable or call) cannot be compared statically and are skipped,
  # mirroring handler_name/2.
  defp validate_tool_names!(tool_dispatch) do
    tool_dispatch
    |> Enum.map(fn {name, _fname, _scopes} -> name end)
    |> Enum.filter(&is_binary/1)
    |> validate_unique_tool_names!()
  end

  defp validate_unique_tool_names!(names) do
    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case duplicates do
      [] ->
        :ok

      dups ->
        raise ArgumentError, "duplicate tool name(s): #{Enum.map_join(dups, ", ", &inspect/1)}"
    end
  end

  # Generates a deterministic private handler name. Determinism matters because Mix's
  # incremental compiler assumes stable output for unchanged sources.
  defp handler_name(prefix, name) when is_binary(name) do
    sanitized = String.replace(name, ~r/[^A-Za-z0-9_]/, "_")
    String.to_atom("__mcp_#{prefix}_#{sanitized}_#{:erlang.phash2(name)}__")
  end

  defp handler_name(prefix, name_ast) do
    String.to_atom("__mcp_#{prefix}_#{:erlang.phash2(name_ast)}__")
  end

  @doc false
  defmacro __before_compile__(env) do
    mod = env.module
    opts = Module.get_attribute(mod, :mcp_opts) || []

    tool_dispatch = Module.get_attribute(mod, :mcp_tool_dispatch) || []
    validate_tool_names!(tool_dispatch)

    has_tools? = tool_dispatch != []
    has_resources? = Module.get_attribute(mod, :mcp_resources) != []
    has_templates? = Module.get_attribute(mod, :mcp_resource_templates) != []
    has_prompts? = Module.get_attribute(mod, :mcp_prompt_dispatch) != []

    flags =
      derive_flags(env, opts, %{
        tools: has_tools?,
        resources: has_resources? or has_templates?,
        templates: has_templates?,
        prompts: has_prompts?
      })

    blocks =
      [
        maybe_tools(has_tools?),
        maybe_resources(has_resources? or has_templates?, has_templates?),
        maybe_prompts(has_prompts?),
        capabilities_ast(opts, flags)
      ]
      |> Enum.reject(&is_nil/1)

    {:__block__, [], blocks}
  end

  defp maybe_tools(false), do: nil

  defp maybe_tools(true) do
    quote do
      @doc false
      def __mcp_tools__, do: Enum.reverse(@mcp_tools)

      @impl true
      def list_tools(_cursor, _ctx), do: {:ok, __mcp_tools__()}

      @impl true
      def call_tool(name, args, ctx) do
        case List.keyfind(Enum.reverse(@mcp_tool_dispatch), name, 0) do
          {_name, fname, scopes} ->
            with :ok <- Urchin.Server.__authorize_tool__(scopes, ctx),
                 :ok <- Urchin.Server.__validate_tool_args__(name, args, ctx, __mcp_tools__()) do
              apply(__MODULE__, fname, [args, ctx])
            end

          nil ->
            {:error, Urchin.Error.invalid_params("Unknown tool: " <> name)}
        end
      end
    end
  end

  defp maybe_resources(false, _), do: nil

  defp maybe_resources(true, has_templates?) do
    base =
      quote do
        @doc false
        def __mcp_resources__, do: Enum.reverse(@mcp_resources)

        @impl true
        def list_resources(_cursor, _ctx), do: {:ok, __mcp_resources__()}

        @impl true
        def read_resource(uri, ctx) do
          Urchin.Server.__read_resource__(
            __MODULE__,
            @mcp_resource_dispatch,
            Enum.reverse(@mcp_template_dispatch),
            uri,
            ctx
          )
        end
      end

    if has_templates? do
      quote do
        unquote(base)

        @doc false
        def __mcp_resource_templates__, do: Enum.reverse(@mcp_resource_templates)

        @impl true
        def list_resource_templates(_cursor, _ctx), do: {:ok, __mcp_resource_templates__()}
      end
    else
      base
    end
  end

  defp maybe_prompts(false), do: nil

  defp maybe_prompts(true) do
    quote do
      @doc false
      def __mcp_prompts__, do: Enum.reverse(@mcp_prompts)

      @impl true
      def list_prompts(_cursor, _ctx), do: {:ok, __mcp_prompts__()}

      @impl true
      def get_prompt(name, args, ctx) do
        case List.keyfind(Enum.reverse(@mcp_prompt_dispatch), name, 0) do
          {_name, fname} -> apply(__MODULE__, fname, [args, ctx])
          nil -> {:error, Urchin.Error.invalid_params("Unknown prompt: " <> name)}
        end
      end
    end
  end

  defp capabilities_ast(opts, flags) do
    resolved = Keyword.get(opts, :capabilities, flags)

    quote do
      @impl true
      def capabilities, do: Urchin.Capabilities.server(unquote(Macro.escape(resolved)))
      defoverridable capabilities: 0
    end
  end

  # Computes capability feature flags from declared DSL features and any manually
  # implemented behaviour callbacks.
  defp derive_flags(env, opts, declared) do
    mod = env.module

    tools? = declared.tools or Module.defines?(mod, {:call_tool, 3})
    resources? = declared.resources or Module.defines?(mod, {:read_resource, 2})
    prompts? = declared.prompts or Module.defines?(mod, {:get_prompt, 3})
    subscribe? = Module.defines?(mod, {:subscribe_resource, 2})
    logging? = Keyword.get(opts, :logging, false) or Module.defines?(mod, {:set_log_level, 2})
    completions? = Keyword.get(opts, :completions, false) or Module.defines?(mod, {:complete, 4})

    %{}
    |> put_if(tools?, :tools, %{list_changed: Keyword.get(opts, :tools_list_changed, false)})
    |> put_if(resources?, :resources, %{
      subscribe: subscribe?,
      list_changed: Keyword.get(opts, :resources_list_changed, false)
    })
    |> put_if(prompts?, :prompts, %{
      list_changed: Keyword.get(opts, :prompts_list_changed, false)
    })
    |> put_if(logging?, :logging, true)
    |> put_if(completions?, :completions, true)
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  ## Runtime helpers used by generated code

  @doc false
  @spec __authorize_tool__([String.t()], Context.t()) :: :ok | {:error, Urchin.Error.t()}
  def __authorize_tool__([], _ctx), do: :ok

  def __authorize_tool__(scopes, %Context{} = ctx) do
    if Urchin.Auth.Claims.has_scopes?(ctx.auth, scopes) do
      :ok
    else
      {:error,
       Urchin.Error.invalid_request(
         "Insufficient scope; requires: " <> Enum.join(scopes, " "),
         %{required_scopes: scopes}
       )}
    end
  end

  @doc false
  @spec __validate_tool_args__(String.t(), map(), Context.t(), [Urchin.Tool.t()]) ::
          :ok | {:error, {:invalid_tool_input, String.t()}}
  def __validate_tool_args__(name, args, _ctx, tools) do
    # Use the same effective schema the wire advertises (Tool.default_input_schema/0 when the tool
    # declared none), so validation is not silently skipped for a tool that declared no schema.
    schema =
      Enum.find_value(tools, fn tool ->
        if tool.name == name, do: tool.input_schema || Urchin.Tool.default_input_schema()
      end)

    # By the time args reaches here it is already an object (the dispatcher rejects a non-object
    # CallToolRequestParams.arguments as a protocol error). What remains is input-schema validation
    # (missing required field, wrong property type, ...), which is a tool-input error: the dispatcher
    # shapes it as an isError CallToolResult, not a JSON-RPC error.
    case Urchin.Schema.validate(schema, args) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_tool_input, reason}}
    end
  end

  @doc false
  @spec __server_info__(keyword()) :: map()
  def __server_info__(opts) do
    name = Keyword.get(opts, :name) || raise(ArgumentError, "use Urchin.Server requires :name")

    version =
      Keyword.get(opts, :version) || raise(ArgumentError, "use Urchin.Server requires :version")

    %{name: name, version: version}
    |> put_opt(opts, :title)
    |> put_opt(opts, :description)
    |> put_opt(opts, :websiteUrl, :website_url)
    |> put_opt(opts, :icons)
  end

  defp put_opt(map, opts, wire_key, opt_key \\ nil) do
    opt_key = opt_key || wire_key

    case Keyword.get(opts, opt_key) do
      nil -> map
      value -> Map.put(map, wire_key, value)
    end
  end

  @doc false
  @spec __read_resource__(
          module(),
          [{String.t(), atom()}],
          [{String.t(), atom()}],
          String.t(),
          Context.t()
        ) ::
          {:ok, [map()]} | {:error, Error.t()}
  def __read_resource__(mod, resource_dispatch, template_dispatch, uri, ctx) do
    case List.keyfind(resource_dispatch, uri, 0) do
      {_uri, fname} ->
        apply(mod, fname, [%{ctx | uri: uri}])

      nil ->
        case match_template(template_dispatch, uri) do
          {fname, params} -> apply(mod, fname, [%{ctx | uri: uri, params: params}])
          nil -> {:error, Error.new(-32_002, "Resource not found", %{uri: uri})}
        end
    end
  end

  defp match_template([], _uri), do: nil

  defp match_template([{template, fname} | rest], uri) do
    case Urchin.URITemplate.match(template, uri) do
      {:ok, params} -> {fname, params}
      :error -> match_template(rest, uri)
    end
  end
end
