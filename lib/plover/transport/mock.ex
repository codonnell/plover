defmodule Plover.Transport.Mock do
  @moduledoc """
  Mock transport for testing. Each mock socket is a GenServer process
  that stores enqueued responses and records sent data.

  ## Low-Level API

  Use `enqueue/2` to enqueue raw IMAP wire-format strings:

      Mock.enqueue(socket, "* OK [CAPABILITY IMAP4rev2] Server ready\\r\\n")

  ## High-Level API

  Use struct-based helpers that handle wire encoding and tag tracking
  automatically:

      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
      Mock.enqueue_response(socket, :ok, text: "LOGIN completed")
      Mock.enqueue_response(socket, :ok,
        untagged: [%Mailbox.Exists{count: 10}],
        text: "SELECT completed"
      )

  Tags are auto-generated (A0001, A0002, ...) matching the Connection's
  tag counter. See the [Testing Guide](testing.md) for full examples.
  """

  @behaviour Plover.Transport
  use GenServer

  alias Plover.Protocol.ResponseEncoder
  alias Plover.Response.{Tagged, Continuation}

  # --- Transport behaviour ---

  @impl Plover.Transport
  def connect(_host, _port, _opts) do
    GenServer.start_link(__MODULE__, %{
      controller: self(),
      inbox: :queue.new(),
      sent: [],
      active: false,
      tag_counter: 1
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

  @doc """
  Enqueue a server greeting. Does not increment the tag counter.

  ## Options

    * `:capabilities` - list of capability strings (e.g., `["IMAP4rev2", "IDLE"]`)
    * `:text` - greeting text (default: `"Server ready"`)

  ## Examples

      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2", "IDLE"], text: "Ready")
      Mock.enqueue_greeting(socket, text: "Server ready")
  """
  def enqueue_greeting(socket, opts \\ []) do
    caps = Keyword.get(opts, :capabilities)
    text = Keyword.get(opts, :text, "Server ready")

    code = if caps, do: {:capability, caps}, else: nil
    wire = ResponseEncoder.encode_untagged(:ok, code: code, text: text)
    enqueue(socket, wire)
  end

  @doc """
  Enqueue a tagged response with optional untagged responses preceding it.
  Auto-generates the next tag (A0001, A0002, ...) atomically.

  ## Options

    * `:untagged` - list of response structs to encode before the tagged response
    * `:code` - response code tuple (e.g., `{:capability, ["IMAP4rev2"]}`)
    * `:text` - response text (default: `""`)

  ## Examples

      Mock.enqueue_response(socket, :ok, text: "LOGIN completed")

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Mailbox.Exists{count: 172},
          %Mailbox.Flags{flags: [:seen, :draft]}
        ],
        code: {:read_write, nil},
        text: "SELECT completed"
      )

      Mock.enqueue_response(socket, :no, text: "access denied")
  """
  def enqueue_response(socket, status, opts \\ []) do
    GenServer.call(socket, {:enqueue_response, status, opts})
  end

  @doc """
  Enqueue a continuation response (`+`). Does not increment the tag counter.

  ## Options

    * `:text` - continuation text (default: `""`)

  ## Examples

      Mock.enqueue_continuation(socket, text: "Ready for literal data")
      Mock.enqueue_continuation(socket)
  """
  def enqueue_continuation(socket, opts \\ []) do
    text = Keyword.get(opts, :text, "")
    wire = ResponseEncoder.encode(%Continuation{text: text})
    enqueue(socket, wire)
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

  def handle_call({:enqueue_response, status, opts}, _from, state) do
    tag = "A" <> String.pad_leading(Integer.to_string(state.tag_counter), 4, "0")
    untagged = Keyword.get(opts, :untagged, [])
    code = Keyword.get(opts, :code)
    text = Keyword.get(opts, :text, "")

    untagged_wire = Enum.map(untagged, &ResponseEncoder.encode/1) |> IO.iodata_to_binary()
    tagged_wire = ResponseEncoder.encode(%Tagged{tag: tag, status: status, code: code, text: text})

    wire = untagged_wire <> tagged_wire
    new_inbox = :queue.in(wire, state.inbox)
    {:reply, :ok, %{state | inbox: new_inbox, tag_counter: state.tag_counter + 1}}
  end

  def handle_call({:setopts, opts}, _from, state) do
    case Keyword.get(opts, :active) do
      :once ->
        case :queue.out(state.inbox) do
          {{:value, data}, rest} ->
            # Deliver as charlist to match real :ssl behavior
            Kernel.send(state.controller, {:mock_ssl, self(), String.to_charlist(data)})
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
