defmodule Urchin.Test.SignalingServer do
  @moduledoc false
  # init/1 signals the (inline, under Plug.Test) caller so a test can assert whether the
  # server's init ran during an initialize.

  use Urchin.Server, name: "signaling", version: "1.0.0"

  @impl true
  def init(_arg) do
    send(self(), :init_ran)
    {:ok, nil}
  end

  tool "noop", description: "Does nothing" do
    _ = {args, ctx}
    {:ok, [Urchin.Content.text("ok")]}
  end
end
