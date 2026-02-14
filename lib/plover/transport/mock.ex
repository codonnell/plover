defmodule Plover.Transport.Mock do
  @moduledoc """
  Mock transport for testing. Each mock socket is a GenServer process
  that stores enqueued responses and records sent data.
  """

  @behaviour Plover.Transport
  use GenServer

  # --- Transport behaviour ---

  @impl Plover.Transport
  def connect(_host, _port, _opts) do
    GenServer.start_link(__MODULE__, %{
      controller: self(),
      inbox: :queue.new(),
      sent: [],
      active: false
    })
  end

  @impl Plover.Transport
  def send(socket, data) do
    GenServer.call(socket, {:send, IO.iodata_to_binary(data)})
  end

  @impl Plover.Transport
  def close(socket) do
    GenServer.stop(socket, :normal)
    :ok
  end

  @impl Plover.Transport
  def setopts(socket, opts) do
    GenServer.call(socket, {:setopts, opts})
  end

  @impl Plover.Transport
  def controlling_process(socket, pid) do
    GenServer.call(socket, {:controlling_process, pid})
  end

  @impl Plover.Transport
  def tag, do: :mock_ssl

  # --- Test helpers ---

  @doc """
  Enqueue data that will be delivered to the controlling process
  when active mode is set.
  """
  def enqueue(socket, data) do
    GenServer.call(socket, {:enqueue, data})
  end

  @doc """
  Get all data that was sent through this mock socket.
  """
  def get_sent(socket) do
    GenServer.call(socket, :get_sent)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:send, data}, _from, state) do
    {:reply, :ok, %{state | sent: state.sent ++ [data]}}
  end

  def handle_call({:enqueue, data}, _from, state) do
    new_inbox = :queue.in(data, state.inbox)
    {:reply, :ok, %{state | inbox: new_inbox}}
  end

  def handle_call({:setopts, opts}, _from, state) do
    case Keyword.get(opts, :active) do
      :once ->
        case :queue.out(state.inbox) do
          {{:value, data}, rest} ->
            Kernel.send(state.controller, {:mock_ssl, self(), data})
            {:reply, :ok, %{state | inbox: rest, active: false}}

          {:empty, _} ->
            {:reply, :ok, %{state | active: :once}}
        end

      false ->
        {:reply, :ok, %{state | active: false}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:controlling_process, pid}, _from, state) do
    {:reply, :ok, %{state | controller: pid}}
  end

  def handle_call(:get_sent, _from, state) do
    {:reply, state.sent, state}
  end

  # When data is enqueued while active: :once is already set
  @impl GenServer
  def handle_info(:try_deliver, state) do
    if state.active == :once do
      case :queue.out(state.inbox) do
        {{:value, data}, rest} ->
          Kernel.send(state.controller, {:mock_ssl, self(), data})
          {:noreply, %{state | inbox: rest, active: false}}

        {:empty, _} ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end
end
