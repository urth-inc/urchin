defmodule Urchin.SessionLifecycleTest do
  # async: false — these tests are timing-based and reason about the shared session registry.
  use ExUnit.Case, async: false

  alias Urchin.Session
  alias Urchin.Test.EchoServer

  defp start(opts) do
    Session.start([server: EchoServer, protocol_version: "2025-11-25"] ++ opts)
  end

  defp wait_until_gone(id, tries \\ 200) do
    cond do
      Session.whereis(id) == nil -> :ok
      tries == 0 -> :timeout
      true -> Process.sleep(10) && wait_until_gone(id, tries - 1)
    end
  end

  test "an idle session is terminated after the idle timeout" do
    {:ok, id, _pid} = start(idle_timeout: 50)
    assert wait_until_gone(id) == :ok
  end

  test "a session is terminated after its max lifetime regardless of activity" do
    {:ok, id, pid} = start(max_lifetime: 50)
    Session.snapshot(pid)
    assert wait_until_gone(id) == :ok
  end

  test "an in-flight request prevents idle reaping until it finishes" do
    {:ok, id, pid} = start(idle_timeout: 50)
    task = spawn(fn -> Process.sleep(:infinity) end)
    Session.start_request(pid, "r1", task, self())

    Process.sleep(150)
    assert Session.whereis(id) == pid, "session was reaped while a request was in flight"

    Session.finish_request(pid, "r1")
    assert wait_until_gone(id) == :ok
    Process.exit(task, :kill)
  end

  test "without a timeout a session is not reaped" do
    {:ok, id, _pid} = start([])
    Process.sleep(80)
    assert Session.whereis(id) != nil
    Session.terminate(Session.whereis(id))
  end

  test "max_sessions rejects new sessions beyond the cap" do
    cap = Registry.count(Urchin.Session.Registry) + 1
    {:ok, id, _pid} = start(max_sessions: cap)
    assert {:error, :max_sessions} = start(max_sessions: cap)
    Session.terminate(Session.whereis(id))
  end
end
