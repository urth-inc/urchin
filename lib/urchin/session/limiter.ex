defmodule Urchin.Session.Limiter do
  @moduledoc false
  # Serializes the session cap so concurrent `initialize`s cannot exceed `:max_sessions`,
  # and so the cap is enforced *before* `c:Urchin.Server.init/1` runs (a rejected session
  # must not pay init cost). A slot is reserved against the cap, then either handed off to
  # the started session process (and freed automatically when it dies) or released if the
  # session is never started.

  use GenServer

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Atomically reserves a session slot. Returns `{:ok, ref}`, or `{:error, :max_sessions}`
  when `max` is an integer and the cap is already reached. `nil` max means unlimited.
  """
  @spec reserve(non_neg_integer() | nil, GenServer.server()) ::
          {:ok, reference()} | {:error, :max_sessions}
  def reserve(max, server \\ __MODULE__), do: GenServer.call(server, {:reserve, max})

  @doc "Hands a reservation off to the session process, which frees the slot when it dies."
  @spec assign(reference(), pid(), GenServer.server()) :: :ok | {:error, :unknown_reservation}
  def assign(ref, pid, server \\ __MODULE__), do: GenServer.call(server, {:assign, ref, pid})

  @doc """
  Frees a reservation that will not become a session (e.g. init failed).

  Synchronous, so the slot is reclaimed before the caller proceeds rather than leaving a
  transient over-count that could spuriously reject the next reserve.
  """
  @spec release(reference(), GenServer.server()) :: :ok
  def release(ref, server \\ __MODULE__), do: GenServer.call(server, {:release, ref})

  @doc "Returns the number of reserved/active slots."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  @impl true
  def init(:ok), do: {:ok, %{count: 0, slots: %{}}}

  @impl true
  def handle_call({:reserve, max}, {caller, _tag}, state) do
    if is_integer(max) and state.count >= max do
      {:reply, {:error, :max_sessions}, state}
    else
      ref = make_ref()
      monitor = Process.monitor(caller)
      {:reply, {:ok, ref}, add_slot(state, ref, monitor)}
    end
  end

  def handle_call({:assign, ref, pid}, _from, state) do
    case Map.fetch(state.slots, ref) do
      {:ok, old_monitor} ->
        Process.demonitor(old_monitor, [:flush])
        monitor = Process.monitor(pid)
        {:reply, :ok, %{state | slots: Map.put(state.slots, ref, monitor)}}

      :error ->
        {:reply, {:error, :unknown_reservation}, state}
    end
  end

  def handle_call({:release, ref}, _from, state), do: {:reply, :ok, drop_slot(state, ref)}

  def handle_call(:count, _from, state), do: {:reply, state.count, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.slots, fn {_ref, m} -> m == monitor end) do
      {ref, _monitor} -> {:noreply, drop_slot(state, ref)}
      nil -> {:noreply, state}
    end
  end

  defp add_slot(state, ref, monitor) do
    %{state | count: state.count + 1, slots: Map.put(state.slots, ref, monitor)}
  end

  defp drop_slot(state, ref) do
    case Map.pop(state.slots, ref) do
      {nil, _slots} ->
        state

      {monitor, slots} ->
        Process.demonitor(monitor, [:flush])
        %{state | count: state.count - 1, slots: slots}
    end
  end
end
