defmodule Plover do
  @moduledoc """
  IMAP4rev2 client library for Elixir.

  Provides a high-level API for connecting to IMAP servers, authenticating,
  managing mailboxes, and fetching/searching/storing messages.

  ## Quick Start

      {:ok, conn} = Plover.connect("imap.gmail.com")
      {:ok, _} = Plover.login(conn, "user@gmail.com", "password")
      {:ok, _} = Plover.select(conn, "INBOX")
      {:ok, messages} = Plover.fetch(conn, "1:5", [:envelope, :flags, :uid])
      {:ok, _} = Plover.logout(conn)

  ## Architecture

  Each connection is a GenServer (`Plover.Connection`) managing a socket,
  command dispatch, and IMAP state machine. The default transport is SSL
  (implicit TLS on port 993).

  ## Configuration

      # config/config.exs
      config :plover,
        log_truncate_limit: 512   # max bytes for debug log messages (default: 512)

  Set `:log_truncate_limit` to `:infinity` to disable truncation entirely.
  """

  require Logger

  alias Plover.{BodyStructure, Connection, Content}
  alias Plover.Connection.Log
  alias Plover.Response.BodyStructure, as: BS
  alias Plover.Response.Tagged

  @typedoc """
  Result of a COPY or MOVE command when the server returns a COPYUID response code.

  Contains the UID validity of the destination mailbox, along with the source
  and destination UID sets as strings. Returns `nil` when the server omits
  COPYUID (e.g., UIDNOTSTICKY mailboxes or permission restrictions).
  """
  @type copy_result ::
          %{uid_validity: pos_integer(), source_uids: String.t(), dest_uids: String.t()} | nil

  @default_port 993

  @doc """
  Connects to an IMAP server over implicit TLS.

  Returns `{:ok, pid}` where `pid` is the connection process, or
  `{:error, reason}` on failure.

  ## Options

    * `:port` - port number (default: 993)
    * `:transport` - transport module (default: `Plover.Transport.SSL`)
    * `:socket` - pre-established socket (for testing with `Plover.Transport.Mock`)
    * `:ssl_opts` - additional SSL options
    * `:on_unsolicited_response` - callback function invoked for untagged
      server responses received outside of IDLE.
      See the [Unsolicited Responses](unsolicited-responses.md) guide.

  ## Examples

      {:ok, conn} = Plover.connect("imap.example.com")
      {:ok, conn} = Plover.connect("imap.example.com", port: 993)

  """
  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(host, opts \\ []) do
    connect(host, Keyword.get(opts, :port, @default_port), opts)
  end

  @doc """
  Connects to an IMAP server on the given port over implicit TLS.

  This 3-arity form is useful for testing with `Plover.Transport.Mock`,
  where the port is passed as a positional argument alongside transport
  options.

  ## Options

    * `:transport` - transport module (default: `Plover.Transport.SSL`)
    * `:socket` - pre-established socket (for testing with `Plover.Transport.Mock`)
    * `:ssl_opts` - additional SSL options
    * `:on_unsolicited_response` - callback function invoked for untagged
      server responses received outside of IDLE.
      See the [Unsolicited Responses](unsolicited-responses.md) guide.

  ## Examples

      # Testing with the mock transport
      {:ok, socket} = Plover.Transport.Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
      {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)

  """
  @spec connect(String.t(), :inet.port_number(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(host, port, opts) do
    transport = Keyword.get(opts, :transport, Plover.Transport.SSL)
    on_unsolicited = Keyword.get(opts, :on_unsolicited_response)

    conn_opts =
      [transport: transport]
      |> then(fn o ->
        if on_unsolicited, do: Keyword.put(o, :on_unsolicited_response, on_unsolicited), else: o
      end)

    case Keyword.get(opts, :socket) do
      nil ->
        ssl_opts = Keyword.get(opts, :ssl_opts, [])

        case transport.connect(host, port, ssl_opts) do
          {:ok, socket} ->
            Log.connected(host, port)
            Connection.start_link([{:socket, socket} | conn_opts])

          {:error, _} = error ->
            Logger.warning(fn ->
              {"Connection failed to #{host}:#{port}: #{inspect(elem(error, 1))}",
               imap_event: :connect_failed}
            end)

            error
        end

      socket ->
        Connection.start_link([{:socket, socket} | conn_opts])
    end
  end

  @doc """
  Logs in with a username and password using the IMAP LOGIN command.

  Returns `{:ok, response}` on success or `{:error, response}` if the
  server rejects the credentials.
  """
  @spec login(pid(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate login(conn, user, password), to: Connection

  @doc """
  Authenticates using the SASL PLAIN mechanism.

  Encodes the credentials per RFC 4616 and sends an AUTHENTICATE PLAIN command.
  """
  @spec authenticate(pid(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def authenticate(conn, user, password) do
    Connection.authenticate(conn, "PLAIN", user, password)
  end

  @doc """
  Authenticates using the XOAUTH2 mechanism.

  Encodes the username and OAuth2 access token, then sends an
  AUTHENTICATE XOAUTH2 command. Used with providers like Gmail.
  """
  @spec authenticate_xoauth2(pid(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate authenticate_xoauth2(conn, user, token), to: Connection

  @doc """
  Selects a mailbox for read-write access.

  The connection transitions to the `:selected` state. Untagged responses
  include mailbox metadata (EXISTS count, FLAGS, UIDVALIDITY, etc.) which
  can be retrieved via `Plover.Connection.mailbox_info/1`.
  """
  @spec select(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate select(conn, mailbox), to: Connection

  @doc """
  Selects a mailbox for read-only access.

  Identical to `select/2` but the server will not allow flag modifications.
  """
  @spec examine(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate examine(conn, mailbox), to: Connection

  @doc "Creates a new mailbox on the server."
  @spec create(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate create(conn, mailbox), to: Connection

  @doc "Deletes a mailbox from the server."
  @spec delete(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate delete(conn, mailbox), to: Connection

  @doc """
  Closes the currently selected mailbox.

  Permanently removes any messages with the `\\Deleted` flag and transitions
  the connection back to the `:authenticated` state.
  """
  @spec close(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate close(conn), to: Connection

  @doc """
  Unselects the currently selected mailbox without expunging.

  Unlike `close/1`, does not remove `\\Deleted` messages. Transitions
  the connection back to the `:authenticated` state.
  """
  @spec unselect(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate unselect(conn), to: Connection

  @doc "Permanently removes all messages with the `\\Deleted` flag from the selected mailbox."
  @spec expunge(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate expunge(conn), to: Connection

  @doc """
  Lists mailboxes matching a pattern.

  Returns `{:ok, [%Plover.Response.Mailbox.List{}]}`. The `reference` is
  typically `""` and `pattern` uses `*` as a wildcard (e.g., `"*"` for all
  mailboxes, `"INBOX/*"` for children of INBOX).
  """
  @spec list(pid(), String.t(), String.t()) ::
          {:ok, [Plover.Response.Mailbox.List.t()]} | {:error, term()}
  defdelegate list(conn, reference, pattern), to: Connection

  @doc """
  Returns status information for a mailbox without selecting it.

  The `attrs` parameter is a list of status attributes to query.

  ## Attributes

    * `:messages` - number of messages
    * `:unseen` - number of unseen messages
    * `:uid_next` - next UID value
    * `:uid_validity` - UID validity value
    * `:recent` - number of recent messages

  """
  @spec status(pid(), String.t(), [Plover.Types.status_attr()]) ::
          {:ok, Plover.Response.Mailbox.Status.t()} | {:error, term()}
  defdelegate status(conn, mailbox, attrs), to: Connection

  @doc """
  Fetches message data for a sequence set.

  Returns `{:ok, [%Plover.Response.Message.Fetch{}]}` with one entry per
  matched message. Each entry has a `.seq` (sequence number) and `.attrs`
  map containing the requested data.

  ## Fetch attributes

    * `:envelope` - parsed envelope (subject, from, to, date, etc.)
    * `:flags` - list of flag atoms (`:seen`, `:flagged`, etc.)
    * `:uid` - unique identifier
    * `:body_structure` - MIME structure
    * `:internal_date` - server receipt date
    * `:rfc822_size` - message size in bytes
    * `{:body, section}` - body content (sets `\\Seen` flag)
    * `{:body_peek, section}` - body content (does not set `\\Seen`)

  ## Examples

      {:ok, messages} = Plover.fetch(conn, "1:5", [:envelope, :flags, :uid])
      {:ok, [msg]} = Plover.fetch(conn, "1", [{:body_peek, "HEADER"}])

  """
  @spec fetch(pid(), String.t(), [Plover.Types.fetch_attr()]) ::
          {:ok, [Plover.Response.Message.Fetch.t()]} | {:error, term()}
  defdelegate fetch(conn, sequence, attrs), to: Connection

  @doc """
  Searches for messages matching the given criteria.

  The `criteria` is a raw IMAP search string sent directly to the server.
  Returns `{:ok, %Plover.Response.ESearch{}}` with result fields like
  `.count`, `.min`, `.max`, and `.all`.

  ## Examples

      {:ok, results} = Plover.search(conn, "UNSEEN")
      {:ok, results} = Plover.search(conn, "FROM \\"user@example.com\\" SINCE 1-Jan-2024")

  """
  @spec search(pid(), String.t()) :: {:ok, Plover.Response.ESearch.t()} | {:error, term()}
  defdelegate search(conn, criteria), to: Connection

  @doc """
  Modifies flags on messages in the selected mailbox.

  The `action` determines how flags are applied:

    * `:add` - adds the given flags (`+FLAGS`)
    * `:remove` - removes the given flags (`-FLAGS`)
    * `:set` - replaces all flags with the given list (`FLAGS`)

  ## Examples

      Plover.store(conn, "1:3", :add, [:seen])
      Plover.store(conn, "5", :remove, [:deleted])
      Plover.store(conn, "1:*", :set, [:seen, :flagged])

  """
  @spec store(pid(), String.t(), Plover.Types.store_action(), [Plover.Types.flag()]) ::
          {:ok, term()} | {:error, term()}
  defdelegate store(conn, sequence, action, flags), to: Connection

  @doc """
  Copies messages identified by `sequence` to the given mailbox.

  On success, returns `{:ok, copy_result}` where `copy_result` is a map
  containing the COPYUID response code data, or `nil` if the server omits it.

  ## Examples

      {:ok, %{uid_validity: 38505, source_uids: "304,319:320", dest_uids: "3956:3958"}} =
        Plover.copy(conn, "2:4", "meeting")

  """
  @spec copy(pid(), String.t(), String.t()) :: {:ok, copy_result()} | {:error, Tagged.t()}
  defdelegate copy(conn, sequence, mailbox), to: Connection

  @doc """
  Moves messages identified by `sequence` to the given mailbox.

  On success, returns `{:ok, copy_result}` where `copy_result` is a map
  containing the COPYUID response code data, or `nil` if the server omits it.

  ## Examples

      {:ok, %{uid_validity: 38505, source_uids: "100:102", dest_uids: "3956:3958"}} =
        Plover.move(conn, "1:3", "Archive")

  """
  @spec move(pid(), String.t(), String.t()) :: {:ok, copy_result()} | {:error, Tagged.t()}
  defdelegate move(conn, sequence, mailbox), to: Connection

  @doc "Sends a NOOP command, which can trigger pending untagged responses."
  @spec noop(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate noop(conn), to: Connection

  @doc """
  Logs out and terminates the connection process.

  The server is sent a LOGOUT command and the GenServer is stopped.
  The `conn` pid is no longer valid after this call.
  """
  @spec logout(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate logout(conn), to: Connection

  @doc "Requests the server's capability list. Returns `{:ok, [String.t()]}`."
  @spec capability(pid()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate capability(conn), to: Connection

  @doc """
  Appends a message to the given mailbox.

  The `message` is the raw RFC 2822 message content as a binary. It is sent
  to the server using the IMAP literal mechanism.

  ## Options

    * `:flags` - list of flag atoms to set (e.g., `[:seen, :draft]`)
    * `:date` - internal date string (e.g., `"14-Jul-2024 02:44:25 -0700"`)

  """
  @spec append(pid(), String.t(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate append(conn, mailbox, message, opts \\ []), to: Connection

  @doc """
  Enters IDLE mode for real-time mailbox notifications.

  The `callback` function is invoked for each untagged response received
  while idling (e.g., `%Plover.Response.Mailbox.Exists{}`,
  `%Plover.Response.Message.Expunge{}`).

  Returns `:ok` once the server acknowledges IDLE. Call `idle_done/1`
  to exit IDLE mode before issuing other commands.
  """
  @spec idle(pid(), (term() -> any())) :: :ok | {:error, term()}
  defdelegate idle(conn, callback), to: Connection

  @doc "Exits IDLE mode. Must be called before issuing other commands."
  @spec idle_done(pid()) :: {:ok, term()} | {:error, term()}
  defdelegate idle_done(conn), to: Connection

  # UID variants

  @doc "Fetches message data by UID. See `fetch/3` for attribute options."
  @spec uid_fetch(pid(), String.t(), [Plover.Types.fetch_attr()]) ::
          {:ok, [Plover.Response.Message.Fetch.t()]} | {:error, term()}
  defdelegate uid_fetch(conn, sequence, attrs), to: Connection

  @doc """
  Fetches and decodes body parts for a message by UID.

  Accepts the `{section, %BodyStructure{}}` tuples returned by
  `Plover.BodyStructure.find_parts/2` or `Plover.BodyStructure.flatten/1`,
  fetches the raw content for each section using `BODY.PEEK` (which does not
  set the `\\Seen` flag), and decodes it automatically.

  Text parts (`text/*`) are both transfer-decoded and charset-converted to
  UTF-8. All other parts are transfer-decoded only, returning raw bytes.

  Returns `{:ok, [{section, decoded_binary}]}` in the same order as the
  input, or `{:error, response}` if the FETCH command fails.

  ## Examples

      # Fetch and decode the text/plain part
      [{section, part}] = Plover.BodyStructure.find_parts(bs, "text/plain")
      {:ok, [{"1", text}]} = Plover.fetch_parts(conn, uid, [{section, part}])

      # Fetch multiple parts at once
      parts = Plover.BodyStructure.find_parts(bs, "text/*")
      {:ok, decoded} = Plover.fetch_parts(conn, uid, parts)

  """
  @spec fetch_parts(pid(), String.t(), [{String.t(), BS.t()}]) ::
          {:ok, [{String.t(), binary()}]} | {:error, term()}
  def fetch_parts(_conn, _uid, []), do: {:ok, []}

  def fetch_parts(conn, uid, parts) do
    fetch_attrs = Enum.map(parts, fn {section, _} -> {:body_peek, section} end)
    sections = MapSet.new(parts, fn {section, _} -> section end)

    with {:ok, messages} <- uid_fetch(conn, uid, fetch_attrs),
         {:ok, msg} <- find_body_response(messages, sections) do
      decode_all(parts, msg)
    end
  end

  defp find_body_response(messages, sections) do
    case Enum.find(messages, fn msg ->
           body = Map.get(msg.attrs, :body, %{})
           Enum.any?(sections, &Map.has_key?(body, &1))
         end) do
      nil -> {:error, :no_body_data}
      msg -> {:ok, msg}
    end
  end

  defp decode_all(parts, msg) do
    Enum.reduce_while(parts, {:ok, []}, fn {section, part}, {:ok, acc} ->
      raw = msg.attrs.body[section]

      case decode_part(raw, part) do
        {:ok, data} -> {:cont, {:ok, [{section, data} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp decode_part(raw, %BS{} = part) do
    encoding = BodyStructure.encoding(part)

    if String.upcase(part.type || "") == "TEXT" do
      Content.decode(raw, encoding, BodyStructure.charset(part))
    else
      Content.decode(raw, encoding)
    end
  end

  @doc "Searches for messages by UID. See `search/2` for criteria format."
  @spec uid_search(pid(), String.t()) :: {:ok, Plover.Response.ESearch.t()} | {:error, term()}
  defdelegate uid_search(conn, criteria), to: Connection

  @doc "Modifies flags on messages by UID. See `store/4` for action options."
  @spec uid_store(pid(), String.t(), Plover.Types.store_action(), [Plover.Types.flag()]) ::
          {:ok, term()} | {:error, term()}
  defdelegate uid_store(conn, sequence, action, flags), to: Connection

  @doc """
  Copies messages to another mailbox by UID.

  On success, returns `{:ok, copy_result}` where `copy_result` is a map
  containing the COPYUID response code data, or `nil` if the server omits it.
  """
  @spec uid_copy(pid(), String.t(), String.t()) :: {:ok, copy_result()} | {:error, Tagged.t()}
  defdelegate uid_copy(conn, sequence, mailbox), to: Connection

  @doc """
  Moves messages to another mailbox by UID.

  On success, returns `{:ok, copy_result}` where `copy_result` is a map
  containing the COPYUID response code data, or `nil` if the server omits it.
  """
  @spec uid_move(pid(), String.t(), String.t()) :: {:ok, copy_result()} | {:error, Tagged.t()}
  defdelegate uid_move(conn, sequence, mailbox), to: Connection

  @doc "Expunges specific messages by UID, rather than all `\\Deleted` messages."
  @spec uid_expunge(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate uid_expunge(conn, sequence), to: Connection
end
