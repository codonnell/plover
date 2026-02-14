defmodule Plover.Connection do
  @moduledoc """
  GenServer managing a single IMAP connection.

  Handles socket I/O, command dispatch, response accumulation,
  and connection state machine transitions.
  """

  use GenServer

  alias Plover.Connection.State
  alias Plover.Command
  alias Plover.Protocol.{Tokenizer, Parser, CommandBuilder}
  alias Plover.Response.{Tagged, Continuation, Mailbox, Message, ESearch}

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the current connection state (:not_authenticated, :authenticated, :selected, :logout)"
  def state(conn), do: GenServer.call(conn, :get_state)

  @doc "Get current capabilities"
  def capabilities(conn), do: GenServer.call(conn, :get_capabilities)

  @doc "Get mailbox info after SELECT/EXAMINE"
  def mailbox_info(conn), do: GenServer.call(conn, :get_mailbox_info)

  # --- Commands ---

  def capability(conn), do: GenServer.call(conn, {:command, "CAPABILITY", []})
  def noop(conn), do: GenServer.call(conn, {:command, "NOOP", []})

  def logout(conn) do
    result = GenServer.call(conn, {:command, "LOGOUT", []})
    # Stop the GenServer after logout
    GenServer.stop(conn, :normal)
    result
  end

  def login(conn, user, pass) do
    GenServer.call(conn, {:command, "LOGIN", [user, pass]})
  end

  def authenticate(conn, mechanism, user, password) do
    encoded = Plover.Auth.Plain.encode(user, password)
    GenServer.call(conn, {:command, "AUTHENTICATE", [mechanism, encoded]})
  end

  def authenticate_xoauth2(conn, user, token) do
    encoded = Plover.Auth.XOAuth2.encode(user, token)
    GenServer.call(conn, {:command, "AUTHENTICATE", ["XOAUTH2", encoded]})
  end

  def select(conn, mailbox), do: GenServer.call(conn, {:command, "SELECT", [mailbox]})
  def examine(conn, mailbox), do: GenServer.call(conn, {:command, "EXAMINE", [mailbox]})
  def create(conn, mailbox), do: GenServer.call(conn, {:command, "CREATE", [mailbox]})
  def delete(conn, mailbox), do: GenServer.call(conn, {:command, "DELETE", [mailbox]})
  def close(conn), do: GenServer.call(conn, {:command, "CLOSE", []})
  def unselect(conn), do: GenServer.call(conn, {:command, "UNSELECT", []})
  def expunge(conn), do: GenServer.call(conn, {:command, "EXPUNGE", []})

  def append(conn, mailbox, message, opts \\ []) do
    flags = Keyword.get(opts, :flags)
    date = Keyword.get(opts, :date)

    args = [mailbox]
    args = if flags, do: args ++ [{:raw, flags_to_string(flags)}], else: args
    args = if date, do: args ++ [date], else: args
    args = args ++ [{:literal, message}]

    GenServer.call(conn, {:command, "APPEND", args})
  end

  def list(conn, reference, pattern) do
    GenServer.call(conn, {:command, "LIST", [reference, pattern]})
  end

  def status(conn, mailbox, attrs) do
    attr_str = attrs |> Enum.map(&status_attr_to_string/1) |> Enum.join(" ")
    GenServer.call(conn, {:command, "STATUS", [mailbox, {:raw, "(#{attr_str})"}]})
  end

  def fetch(conn, sequence, attrs) do
    attr_str = fetch_attrs_to_string(attrs)
    GenServer.call(conn, {:command, "FETCH", [sequence, {:raw, attr_str}]})
  end

  def search(conn, criteria) do
    GenServer.call(conn, {:command, "SEARCH", [criteria]})
  end

  def store(conn, sequence, action, flags) do
    action_str = store_action_to_string(action)
    flag_str = flags_to_string(flags)
    GenServer.call(conn, {:command, "STORE", [sequence, action_str, {:raw, flag_str}]})
  end

  def copy(conn, sequence, mailbox) do
    GenServer.call(conn, {:command, "COPY", [sequence, mailbox]})
  end

  def move(conn, sequence, mailbox) do
    GenServer.call(conn, {:command, "MOVE", [sequence, mailbox]})
  end

  def idle(conn, callback) do
    GenServer.call(conn, {:idle, callback})
  end

  def idle_done(conn) do
    GenServer.call(conn, :idle_done)
  end

  # UID variants
  def uid_fetch(conn, sequence, attrs) do
    attr_str = fetch_attrs_to_string(attrs)
    GenServer.call(conn, {:command, "UID FETCH", [sequence, {:raw, attr_str}]})
  end

  def uid_store(conn, sequence, action, flags) do
    action_str = store_action_to_string(action)
    flag_str = flags_to_string(flags)
    GenServer.call(conn, {:command, "UID STORE", [sequence, action_str, {:raw, flag_str}]})
  end

  def uid_copy(conn, sequence, mailbox) do
    GenServer.call(conn, {:command, "UID COPY", [sequence, mailbox]})
  end

  def uid_move(conn, sequence, mailbox) do
    GenServer.call(conn, {:command, "UID MOVE", [sequence, mailbox]})
  end

  def uid_search(conn, criteria) do
    GenServer.call(conn, {:command, "UID SEARCH", [criteria]})
  end

  def uid_expunge(conn, sequence) do
    GenServer.call(conn, {:command, "UID EXPUNGE", [sequence]})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    socket = Keyword.fetch!(opts, :socket)

    state = %State{
      transport: transport,
      socket: socket
    }

    # Transfer socket ownership to this GenServer
    :ok = transport.controlling_process(socket, self())
    # Set active: :once to receive the greeting
    :ok = transport.setopts(socket, active: :once)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state.conn_state, state}
  end

  def handle_call(:get_capabilities, _from, %State{} = state) do
    {:reply, MapSet.to_list(state.capabilities), state}
  end

  def handle_call(:get_mailbox_info, _from, %State{} = state) do
    {:reply, state.mailbox_info, state}
  end

  def handle_call({:command, name, args}, from, %State{} = state) do
    {tag, state} = State.next_tag(state)
    cmd = %Command{tag: tag, name: name, args: args}
    iodata = CommandBuilder.build(cmd)

    case iodata do
      {:literal, first_part, literal_data} ->
        :ok = state.transport.send(state.socket, first_part)
        pending = Map.put(state.pending, tag, %{from: from, command: name, responses: [], literal: literal_data})
        state = %{state | pending: pending}
        :ok = state.transport.setopts(state.socket, active: :once)
        {:noreply, state}

      _ ->
        :ok = state.transport.send(state.socket, iodata)
        pending = Map.put(state.pending, tag, %{from: from, command: name, responses: []})
        state = %{state | pending: pending}
        :ok = state.transport.setopts(state.socket, active: :once)
        {:noreply, state}
    end
  end

  def handle_call({:idle, callback}, from, %State{} = state) do
    {tag, state} = State.next_tag(state)
    cmd = %Command{tag: tag, name: "IDLE", args: []}
    :ok = state.transport.send(state.socket, CommandBuilder.build(cmd))

    state = %{state | idle_state: %{tag: tag, from: from, callback: callback}}
    :ok = state.transport.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_call(:idle_done, from, %State{} = state) do
    case state.idle_state do
      %{tag: tag} ->
        :ok = state.transport.send(state.socket, CommandBuilder.build_done())
        pending = Map.put(state.pending, tag, %{from: from, command: "IDLE", responses: []})
        state = %{state | idle_state: nil, pending: pending}
        :ok = state.transport.setopts(state.socket, active: :once)
        {:noreply, state}

      nil ->
        {:reply, {:error, :not_idle}, state}
    end
  end

  @impl true
  def handle_info({transport_tag, _socket, data}, %State{} = state)
      when transport_tag in [:ssl, :mock_ssl] do
    buffer = state.buffer <> IO.iodata_to_binary(data)
    state = %{state | buffer: buffer}
    state = process_buffer(state)

    # Only request more data if we have pending commands or are in idle
    if map_size(state.pending) > 0 or state.idle_state != nil do
      :ok = state.transport.setopts(state.socket, active: :once)
    end

    {:noreply, state}
  end

  def handle_info({:ssl_closed, _socket}, %State{} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _socket, reason}, %State{} = state) do
    {:stop, {:ssl_error, reason}, state}
  end

  # --- Buffer processing ---

  defp process_buffer(%State{} = state) do
    case Tokenizer.tokenize(state.buffer) do
      {:ok, tokens, rest} ->
        state = %{state | buffer: rest}
        state = handle_parsed_response(tokens, state)
        # Try to parse more from remaining buffer
        if byte_size(rest) > 0, do: process_buffer(state), else: state

      {:error, _} ->
        # Incomplete data, wait for more
        state
    end
  end

  defp handle_parsed_response(tokens, %State{} = state) do
    case Parser.parse(tokens) do
      {:ok, response} ->
        dispatch_response(response, state)

      {:error, _reason} ->
        state
    end
  end

  # --- Response dispatch ---

  # Greeting (untagged OK/PREAUTH/BYE when no pending commands)
  defp dispatch_response({:ok, code, _text}, %State{} = state) when map_size(state.pending) == 0 and state.idle_state == nil do
    state = maybe_store_capabilities(code, state)
    state
  end

  defp dispatch_response({:preauth, code, _text}, %State{} = state) when map_size(state.pending) == 0 do
    state = maybe_store_capabilities(code, state)
    %{state | conn_state: :authenticated}
  end

  defp dispatch_response({:bye, _text}, %State{} = state) when map_size(state.pending) == 0 do
    %{state | conn_state: :logout}
  end

  # Tagged response — completes a pending command
  defp dispatch_response(%Tagged{tag: tag} = resp, %State{} = state) do
    case Map.pop(state.pending, tag) do
      {nil, _pending} ->
        state

      {%{from: from, command: command, responses: responses}, pending} ->
        state = %{state | pending: pending}
        state = apply_state_transition(command, resp, state)
        reply = build_reply(command, resp, responses)
        GenServer.reply(from, reply)
        state
    end
  end

  # Continuation response
  defp dispatch_response(%Continuation{} = _cont, %State{} = state) do
    case state.idle_state do
      %{from: from} ->
        # IDLE continuation — tell caller we're now idling
        GenServer.reply(from, :ok)
        state

      nil ->
        # Could be AUTHENTICATE or APPEND continuation
        # For now, handle APPEND literal sending
        state = maybe_send_literal(state)
        state
    end
  end

  # Untagged CAPABILITY
  defp dispatch_response({:capability, caps}, %State{} = state) do
    state = %{state | capabilities: MapSet.new(caps)}
    accumulate_untagged({:capability, caps}, state)
  end

  # Untagged FLAGS
  defp dispatch_response(%Mailbox.Flags{} = flags_resp, %State{} = state) do
    # Accumulate on pending command or update mailbox info
    state = accumulate_untagged(flags_resp, state)
    update_mailbox_info(state, :flags, flags_resp.flags)
  end

  # Untagged EXISTS
  defp dispatch_response(%Mailbox.Exists{} = exists, %State{} = state) do
    state = accumulate_untagged(exists, state)

    case state.idle_state do
      %{callback: callback} ->
        callback.(exists)
        state

      nil ->
        update_mailbox_info(state, :exists, exists.count)
    end
  end

  # Untagged LIST
  defp dispatch_response(%Mailbox.List{} = list, %State{} = state) do
    accumulate_untagged(list, state)
  end

  # Untagged STATUS
  defp dispatch_response(%Mailbox.Status{} = status, %State{} = state) do
    accumulate_untagged(status, state)
  end

  # Untagged ESEARCH
  defp dispatch_response(%ESearch{} = esearch, %State{} = state) do
    accumulate_untagged(esearch, state)
  end

  # Untagged FETCH
  defp dispatch_response(%Message.Fetch{} = fetch, %State{} = state) do
    case state.idle_state do
      %{callback: callback} ->
        callback.(fetch)
        state

      nil ->
        accumulate_untagged(fetch, state)
    end
  end

  # Untagged EXPUNGE
  defp dispatch_response(%Message.Expunge{} = expunge, %State{} = state) do
    case state.idle_state do
      %{callback: callback} ->
        callback.(expunge)
        state

      nil ->
        accumulate_untagged(expunge, state)
    end
  end

  # Untagged OK/NO/BAD with response codes
  defp dispatch_response({status, code, _text}, %State{} = state)
       when status in [:ok, :no, :bad] do
    state = maybe_store_capabilities(code, state)

    case code do
      {:uid_validity, _} -> update_mailbox_info(state, :uid_validity, elem(code, 1))
      {:uid_next, _} -> update_mailbox_info(state, :uid_next, elem(code, 1))
      _ -> state
    end
  end

  defp dispatch_response({:bye, _text}, %State{} = state) do
    accumulate_untagged({:bye, nil}, state)
  end

  defp dispatch_response({:enabled, _caps}, %State{} = state), do: state

  defp dispatch_response(_response, %State{} = state), do: state

  # --- Accumulate untagged responses ---

  defp accumulate_untagged(response, %State{} = state) do
    # Find the first pending command and accumulate the response
    case first_pending(state) do
      {tag, entry} ->
        entry = %{entry | responses: entry.responses ++ [response]}
        %{state | pending: Map.put(state.pending, tag, entry)}

      nil ->
        state
    end
  end

  defp first_pending(%State{} = state) do
    case Map.to_list(state.pending) do
      [{tag, entry} | _] -> {tag, entry}
      [] -> nil
    end
  end

  # --- State transitions ---

  defp apply_state_transition("LOGIN", %Tagged{status: :ok} = resp, %State{} = state) do
    state = maybe_store_capabilities(resp.code, state)
    %{state | conn_state: :authenticated}
  end

  defp apply_state_transition("AUTHENTICATE", %Tagged{status: :ok} = resp, %State{} = state) do
    state = maybe_store_capabilities(resp.code, state)
    %{state | conn_state: :authenticated}
  end

  defp apply_state_transition("SELECT", %Tagged{status: :ok}, %State{} = state) do
    %{state | conn_state: :selected}
  end

  defp apply_state_transition("EXAMINE", %Tagged{status: :ok}, %State{} = state) do
    %{state | conn_state: :selected}
  end

  defp apply_state_transition("CLOSE", %Tagged{status: :ok}, %State{} = state) do
    %{state | conn_state: :authenticated, selected_mailbox: nil, mailbox_info: nil}
  end

  defp apply_state_transition("UNSELECT", %Tagged{status: :ok}, %State{} = state) do
    %{state | conn_state: :authenticated, selected_mailbox: nil, mailbox_info: nil}
  end

  defp apply_state_transition("LOGOUT", %Tagged{}, %State{} = state) do
    %{state | conn_state: :logout}
  end

  defp apply_state_transition(_command, %Tagged{}, %State{} = state), do: state

  # --- Build reply ---

  defp build_reply(command, %Tagged{status: :ok} = resp, responses) do
    case command do
      "CAPABILITY" ->
        caps =
          Enum.find_value(responses, [], fn
            {:capability, c} -> c
            _ -> nil
          end)

        {:ok, caps}

      cmd when cmd in ["FETCH", "UID FETCH"] ->
        fetches = Enum.filter(responses, &match?(%Message.Fetch{}, &1))
        {:ok, fetches}

      cmd when cmd in ["SEARCH", "UID SEARCH"] ->
        esearch = Enum.find(responses, fn
          %ESearch{} -> true
          _ -> false
        end)
        {:ok, esearch || %ESearch{}}

      "LIST" ->
        lists = Enum.filter(responses, &match?(%Mailbox.List{}, &1))
        {:ok, lists}

      "STATUS" ->
        status = Enum.find(responses, fn
          %Mailbox.Status{} -> true
          _ -> false
        end)
        {:ok, status}

      _ ->
        {:ok, resp}
    end
  end

  defp build_reply(_command, %Tagged{status: status} = resp, _responses)
       when status in [:no, :bad] do
    {:error, resp}
  end

  # --- Helpers ---

  defp maybe_store_capabilities({:capability, caps}, %State{} = state) do
    %{state | capabilities: MapSet.new(caps)}
  end

  defp maybe_store_capabilities(_, %State{} = state), do: state

  defp update_mailbox_info(%State{} = state, key, value) do
    info = state.mailbox_info || %{}
    %{state | mailbox_info: Map.put(info, key, value)}
  end

  defp maybe_send_literal(%State{} = state) do
    # Find pending command with literal data
    case Enum.find(state.pending, fn {_tag, entry} -> Map.has_key?(entry, :literal) end) do
      {tag, %{literal: data} = entry} ->
        :ok = state.transport.send(state.socket, [data, "\r\n"])
        entry = Map.delete(entry, :literal)
        %{state | pending: Map.put(state.pending, tag, entry)}

      nil ->
        state
    end
  end

  defp fetch_attrs_to_string(attrs) when is_list(attrs) do
    strs = Enum.map(attrs, &fetch_attr_to_string/1)

    case strs do
      [single] -> single
      multiple -> "(#{Enum.join(multiple, " ")})"
    end
  end

  defp fetch_attr_to_string(:envelope), do: "ENVELOPE"
  defp fetch_attr_to_string(:flags), do: "FLAGS"
  defp fetch_attr_to_string(:uid), do: "UID"
  defp fetch_attr_to_string(:body_structure), do: "BODYSTRUCTURE"
  defp fetch_attr_to_string(:internal_date), do: "INTERNALDATE"
  defp fetch_attr_to_string(:rfc822_size), do: "RFC822.SIZE"
  defp fetch_attr_to_string({:body, section}), do: "BODY[#{section}]"
  defp fetch_attr_to_string({:body_peek, section}), do: "BODY.PEEK[#{section}]"
  defp fetch_attr_to_string(str) when is_binary(str), do: str

  defp status_attr_to_string(:messages), do: "MESSAGES"
  defp status_attr_to_string(:recent), do: "RECENT"
  defp status_attr_to_string(:unseen), do: "UNSEEN"
  defp status_attr_to_string(:uid_next), do: "UIDNEXT"
  defp status_attr_to_string(:uid_validity), do: "UIDVALIDITY"

  defp store_action_to_string(:set), do: "FLAGS"
  defp store_action_to_string(:add), do: "+FLAGS"
  defp store_action_to_string(:remove), do: "-FLAGS"

  defp flags_to_string(flags) do
    strs = Enum.map(flags, &flag_to_string/1)
    "(#{Enum.join(strs, " ")})"
  end

  defp flag_to_string(:answered), do: "\\Answered"
  defp flag_to_string(:flagged), do: "\\Flagged"
  defp flag_to_string(:deleted), do: "\\Deleted"
  defp flag_to_string(:seen), do: "\\Seen"
  defp flag_to_string(:draft), do: "\\Draft"
  defp flag_to_string(flag) when is_atom(flag), do: Atom.to_string(flag)
  defp flag_to_string(flag) when is_binary(flag), do: flag
end
