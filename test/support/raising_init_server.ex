defmodule Urchin.Test.RaisingInitServer do
  @moduledoc false
  # init/1 raises, to exercise the transport reclaiming a reserved session slot.

  use Urchin.Server, name: "raising", version: "1.0.0"

  @impl true
  def init(_arg), do: raise("init boom")

  tool "noop", description: "Does nothing" do
    _ = {args, ctx}
    {:ok, [Urchin.Content.text("ok")]}
  end
end
