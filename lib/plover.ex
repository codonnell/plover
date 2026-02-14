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
  """

  alias Plover.Connection

  @default_port 993

  @doc """
  Connect to an IMAP server over implicit TLS.

  Options:
  - `:port` - port number (default: 993)
  - `:transport` - transport module (default: `Plover.Transport.SSL`)
  - `:socket` - pre-established socket (for testing with mock transport)
  - `:ssl_opts` - additional SSL options
  """
  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(host, opts \\ []) do
    connect(host, Keyword.get(opts, :port, @default_port), opts)
  end

  @spec connect(String.t(), :inet.port_number(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(host, port, opts) do
    transport = Keyword.get(opts, :transport, Plover.Transport.SSL)

    case Keyword.get(opts, :socket) do
      nil ->
        ssl_opts = Keyword.get(opts, :ssl_opts, [])

        case transport.connect(host, port, ssl_opts) do
          {:ok, socket} ->
            Connection.start_link(transport: transport, socket: socket)

          {:error, _} = error ->
            error
        end

      socket ->
        Connection.start_link(transport: transport, socket: socket)
    end
  end

  @doc "Log in with username and password (LOGIN command)."
  defdelegate login(conn, user, password), to: Connection

  @doc "Authenticate using SASL PLAIN mechanism."
  def authenticate(conn, user, password) do
    Connection.authenticate(conn, "PLAIN", user, password)
  end

  @doc "Authenticate using XOAUTH2 mechanism."
  defdelegate authenticate_xoauth2(conn, user, token), to: Connection

  @doc "Select a mailbox for access."
  defdelegate select(conn, mailbox), to: Connection

  @doc "Select a mailbox for read-only access."
  defdelegate examine(conn, mailbox), to: Connection

  @doc "Create a new mailbox."
  defdelegate create(conn, mailbox), to: Connection

  @doc "Delete a mailbox."
  defdelegate delete(conn, mailbox), to: Connection

  @doc "Close the currently selected mailbox."
  defdelegate close(conn), to: Connection

  @doc "Unselect the currently selected mailbox without expunging."
  defdelegate unselect(conn), to: Connection

  @doc "Permanently remove deleted messages from the selected mailbox."
  defdelegate expunge(conn), to: Connection

  @doc "List mailboxes matching a pattern."
  defdelegate list(conn, reference, pattern), to: Connection

  @doc "Get status information for a mailbox."
  defdelegate status(conn, mailbox, attrs), to: Connection

  @doc "Fetch message data for a sequence set."
  defdelegate fetch(conn, sequence, attrs), to: Connection

  @doc "Search for messages matching criteria."
  defdelegate search(conn, criteria), to: Connection

  @doc "Store flags on messages."
  defdelegate store(conn, sequence, action, flags), to: Connection

  @doc "Copy messages to another mailbox."
  defdelegate copy(conn, sequence, mailbox), to: Connection

  @doc "Move messages to another mailbox."
  defdelegate move(conn, sequence, mailbox), to: Connection

  @doc "Send a NOOP command."
  defdelegate noop(conn), to: Connection

  @doc "Log out and close the connection."
  defdelegate logout(conn), to: Connection

  @doc "Request server capabilities."
  defdelegate capability(conn), to: Connection

  @doc "Append a message to a mailbox. Options: `:flags`, `:date`."
  defdelegate append(conn, mailbox, message, opts \\ []), to: Connection

  @doc "Enter IDLE mode for real-time notifications."
  defdelegate idle(conn, callback), to: Connection

  @doc "Exit IDLE mode."
  defdelegate idle_done(conn), to: Connection

  # UID variants
  @doc "Fetch message data by UID."
  defdelegate uid_fetch(conn, sequence, attrs), to: Connection

  @doc "Search for messages by UID."
  defdelegate uid_search(conn, criteria), to: Connection

  @doc "Store flags on messages by UID."
  defdelegate uid_store(conn, sequence, action, flags), to: Connection

  @doc "Copy messages to another mailbox by UID."
  defdelegate uid_copy(conn, sequence, mailbox), to: Connection

  @doc "Move messages to another mailbox by UID."
  defdelegate uid_move(conn, sequence, mailbox), to: Connection

  @doc "Expunge messages by UID."
  defdelegate uid_expunge(conn, sequence), to: Connection
end
