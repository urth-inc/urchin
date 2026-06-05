defmodule Urchin.Session.LimiterTest do
  use ExUnit.Case, async: true

  alias Urchin.Session.Limiter

  setup do
    name = :"limiter_#{System.unique_integer([:positive])}"
    {:ok, pid} = Limiter.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{limiter: name}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> :timeout
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  test "reserves up to the cap and rejects beyond it", %{limiter: l} do
    assert {:ok, _} = Limiter.reserve(2, l)
    assert {:ok, _} = Limiter.reserve(2, l)
    assert {:error, :max_sessions} = Limiter.reserve(2, l)
    assert Limiter.count(l) == 2
  end

  test "a nil cap is unlimited", %{limiter: l} do
    for _ <- 1..10, do: assert({:ok, _} = Limiter.reserve(nil, l))
    assert Limiter.count(l) == 10
  end

  test "release frees a slot", %{limiter: l} do
    {:ok, ref} = Limiter.reserve(1, l)
    assert {:error, :max_sessions} = Limiter.reserve(1, l)
    Limiter.release(ref, l)
    assert Limiter.count(l) == 0
    assert {:ok, _} = Limiter.reserve(1, l)
  end

  test "a slot is freed when its assigned process dies", %{limiter: l} do
    {:ok, ref} = Limiter.reserve(1, l)
    pid = spawn(fn -> Process.sleep(:infinity) end)
    Limiter.assign(ref, pid, l)
    assert {:error, :max_sessions} = Limiter.reserve(1, l)

    Process.exit(pid, :kill)
    assert wait_until(fn -> Limiter.count(l) == 0 end) == :ok
    assert {:ok, _} = Limiter.reserve(1, l)
  end

  test "assigning an unknown reservation returns an error", %{limiter: l} do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:error, :unknown_reservation} = Limiter.assign(make_ref(), pid, l)
    Process.exit(pid, :kill)
  end

  test "reserve is atomic under concurrency", %{limiter: l} do
    parent = self()

    holders =
      for _ <- 1..50 do
        spawn(fn ->
          send(parent, {:result, Limiter.reserve(1, l)})
          receive do: (:stop -> :ok)
        end)
      end

    results = for _ <- 1..50, do: receive(do: ({:result, r} -> r))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    Enum.each(holders, &send(&1, :stop))
  end
end
