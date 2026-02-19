defmodule Plover.ConnectionTest do
  use ExUnit.Case, async: true

  alias Plover.Connection
  alias Plover.Transport.Mock

  # Helper: start a connection with mock transport and a greeting
  defp start_connection(greeting \\ "* OK IMAP4rev2 server ready\r\n") do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, greeting)
    {:ok, conn} = Connection.start_link(transport: Mock, socket: socket)
    {conn, socket}
  end

  describe "greeting and lifecycle" do
    test "connects and receives greeting" do
      {conn, _socket} = start_connection()
      assert Process.alive?(conn)
    end

    test "connects with PREAUTH greeting" do
      {conn, _socket} = start_connection("* PREAUTH IMAP4rev2 ready\r\n")
      assert Connection.state(conn) == :authenticated
    end

    test "greeting sets not_authenticated state" do
      {conn, _socket} = start_connection()
      assert Connection.state(conn) == :not_authenticated
    end

    test "greeting with CAPABILITY stores capabilities" do
      {conn, _socket} =
        start_connection("* OK [CAPABILITY IMAP4rev2 AUTH=PLAIN IDLE] Ready\r\n")

      caps = Connection.capabilities(conn)
      assert "IMAP4rev2" in caps
      assert "AUTH=PLAIN" in caps
      assert "IDLE" in caps
    end
  end

  describe "LOGIN command" do
    test "successful login transitions to authenticated" do
      {conn, socket} = start_connection()

      Mock.enqueue(socket, "A0001 OK [CAPABILITY IMAP4rev2] LOGIN completed\r\n")
      assert {:ok, _resp} = Connection.login(conn, "user", "pass")
      assert Connection.state(conn) == :authenticated
    end

    test "failed login returns error" do
      {conn, socket} = start_connection()

      Mock.enqueue(socket, "A0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
      assert {:error, resp} = Connection.login(conn, "user", "wrong")
      assert resp.status == :no
      assert Connection.state(conn) == :not_authenticated
    end
  end

  describe "AUTHENTICATE command" do
    test "AUTHENTICATE PLAIN with initial response" do
      {conn, socket} = start_connection()

      Mock.enqueue(socket, "A0001 OK AUTHENTICATE completed\r\n")
      assert {:ok, _resp} = Connection.authenticate(conn, "PLAIN", "user@example.com", "password")
      assert Connection.state(conn) == :authenticated
    end

    test "AUTHENTICATE XOAUTH2" do
      {conn, socket} = start_connection()

      Mock.enqueue(socket, "A0001 OK AUTHENTICATE completed\r\n")

      assert {:ok, _resp} =
               Connection.authenticate_xoauth2(conn, "user@example.com", "oauth_token")

      assert Connection.state(conn) == :authenticated
    end
  end

  describe "CAPABILITY command" do
    test "fetches capabilities" do
      {conn, socket} = start_connection()

      Mock.enqueue(
        socket,
        "* CAPABILITY IMAP4rev2 AUTH=PLAIN IDLE\r\nA0001 OK CAPABILITY completed\r\n"
      )

      assert {:ok, caps} = Connection.capability(conn)
      assert "IMAP4rev2" in caps
      assert "IDLE" in caps
    end
  end

  describe "SELECT command" do
    test "SELECT transitions to selected state" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")

      Mock.enqueue(
        socket,
        "* 172 EXISTS\r\n* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n* OK [UIDVALIDITY 3857529045] UIDs valid\r\n* OK [UIDNEXT 4392] Predicted next UID\r\nA0002 OK [READ-WRITE] SELECT completed\r\n"
      )

      assert {:ok, resp} = Connection.select(conn, "INBOX")
      assert Connection.state(conn) == :selected
      assert resp.status == :ok
    end

    test "SELECT captures mailbox info from untagged responses" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")

      Mock.enqueue(
        socket,
        "* 172 EXISTS\r\n* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n* OK [UIDVALIDITY 3857529045] UIDs valid\r\nA0002 OK [READ-WRITE] SELECT completed\r\n"
      )

      {:ok, _} = Connection.select(conn, "INBOX")
      info = Connection.mailbox_info(conn)
      assert info.exists == 172
      assert :seen in info.flags
    end
  end

  describe "EXAMINE command" do
    test "EXAMINE transitions to selected state" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")

      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK [READ-ONLY] EXAMINE completed\r\n")
      assert {:ok, _} = Connection.examine(conn, "INBOX")
      assert Connection.state(conn) == :selected
    end
  end

  describe "FETCH command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 5 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "fetches message flags", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (FLAGS (\\Seen) UID 100)\r\n* 2 FETCH (FLAGS (\\Seen \\Flagged) UID 101)\r\nA0003 OK FETCH completed\r\n"
      )

      assert {:ok, messages} = Connection.fetch(conn, "1:2", [:flags, :uid])
      assert length(messages) == 2
      [msg1, msg2] = messages
      assert msg1.attrs.uid == 100
      assert :seen in msg1.attrs.flags
      assert msg2.attrs.uid == 101
      assert :flagged in msg2.attrs.flags
    end

    test "fetches envelope", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (ENVELOPE (\"Mon, 7 Feb 1994 21:52:25 -0800\" \"Test\" ((\"John\" NIL \"john\" \"example.com\")) NIL NIL NIL NIL NIL NIL \"<test@example.com>\"))\r\nA0003 OK FETCH completed\r\n"
      )

      assert {:ok, [msg]} = Connection.fetch(conn, "1", [:envelope])
      assert msg.attrs.envelope.subject == "Test"
    end
  end

  describe "SEARCH command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "search returns ESEARCH results", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* ESEARCH (TAG \"A0003\") UID ALL 1:3,5 COUNT 4\r\nA0003 OK SEARCH completed\r\n"
      )

      assert {:ok, esearch} = Connection.search(conn, "ALL")
      assert esearch.count == 4
      assert esearch.all == "1:3,5"
    end
  end

  describe "STORE command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "store flags", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (FLAGS (\\Seen \\Deleted))\r\nA0003 OK STORE completed\r\n"
      )

      assert {:ok, _} = Connection.store(conn, "1", :add, [:deleted])
    end
  end

  describe "COPY and MOVE commands" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "copy messages", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK [COPYUID 38505 1:3 100:102] COPY completed\r\n")
      assert {:ok, _} = Connection.copy(conn, "1:3", "Archive")
    end

    test "move messages", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 EXPUNGE\r\n* 1 EXPUNGE\r\nA0003 OK MOVE completed\r\n"
      )

      assert {:ok, _} = Connection.move(conn, "1:2", "Trash")
    end
  end

  describe "LIST command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      %{conn: conn, socket: socket}
    end

    test "list mailboxes", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren) \"/\" \"Sent\"\r\n* LIST (\\HasChildren) \"/\" \"Work\"\r\nA0002 OK LIST completed\r\n"
      )

      assert {:ok, mailboxes} = Connection.list(conn, "", "*")
      assert length(mailboxes) == 3
      assert Enum.any?(mailboxes, &(&1.name == "INBOX"))
    end
  end

  describe "STATUS command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      %{conn: conn, socket: socket}
    end

    test "get mailbox status", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* STATUS \"INBOX\" (MESSAGES 17 UNSEEN 5)\r\nA0002 OK STATUS completed\r\n"
      )

      assert {:ok, status} = Connection.status(conn, "INBOX", [:messages, :unseen])
      assert status.messages == 17
      assert status.unseen == 5
    end
  end

  describe "IDLE command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "idle receives updates then DONE", %{conn: conn, socket: socket} do
      # Server sends continuation, then an EXISTS update, then we stop idle
      Mock.enqueue(socket, "+ idling\r\n")

      parent = self()

      callback = fn response ->
        send(parent, {:idle_update, response})
      end

      assert :ok = Connection.idle(conn, callback)

      # Simulate server sending an update during IDLE
      Mock.enqueue(socket, "* 11 EXISTS\r\n")
      # Trigger delivery
      Mock.setopts(socket, active: :once)

      assert_receive {:idle_update, _update}, 1000

      # Stop idle
      Mock.enqueue(socket, "A0003 OK IDLE terminated\r\n")
      assert {:ok, _} = Connection.idle_done(conn)
    end
  end

  describe "CLOSE and UNSELECT" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "close transitions back to authenticated", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK CLOSE completed\r\n")
      assert {:ok, _} = Connection.close(conn)
      assert Connection.state(conn) == :authenticated
    end

    test "unselect transitions back to authenticated", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UNSELECT completed\r\n")
      assert {:ok, _} = Connection.unselect(conn)
      assert Connection.state(conn) == :authenticated
    end
  end

  describe "LOGOUT" do
    test "logout closes connection" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "* BYE server logging out\r\nA0001 OK LOGOUT completed\r\n")
      assert {:ok, _} = Connection.logout(conn)
      # Connection should be stopped after logout
      refute Process.alive?(conn)
    end
  end

  describe "NOOP" do
    test "noop returns ok" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK NOOP completed\r\n")
      assert {:ok, _} = Connection.noop(conn)
    end
  end

  describe "CREATE and DELETE" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      %{conn: conn, socket: socket}
    end

    test "create mailbox", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0002 OK CREATE completed\r\n")
      assert {:ok, _} = Connection.create(conn, "NewFolder")
    end

    test "delete mailbox", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0002 OK DELETE completed\r\n")
      assert {:ok, _} = Connection.delete(conn, "OldFolder")
    end
  end

  describe "UID commands" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "uid fetch", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (UID 100 FLAGS (\\Seen))\r\nA0003 OK UID FETCH completed\r\n"
      )

      assert {:ok, [msg]} = Connection.uid_fetch(conn, "100", [:flags])
      assert msg.attrs.uid == 100
    end

    test "uid store", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (FLAGS (\\Seen \\Deleted))\r\nA0003 OK UID STORE completed\r\n"
      )

      assert {:ok, _} = Connection.uid_store(conn, "100", :add, [:deleted])
    end

    test "uid copy", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID COPY completed\r\n")
      assert {:ok, _} = Connection.uid_copy(conn, "100:200", "Archive")
    end

    test "uid move", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID MOVE completed\r\n")
      assert {:ok, _} = Connection.uid_move(conn, "100:200", "Trash")
    end

    test "uid search", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* ESEARCH (TAG \"A0003\") UID COUNT 5\r\nA0003 OK UID SEARCH completed\r\n"
      )

      assert {:ok, esearch} = Connection.uid_search(conn, "ALL")
      assert esearch.count == 5
    end

    test "uid expunge", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 EXPUNGE\r\nA0003 OK UID EXPUNGE completed\r\n"
      )

      assert {:ok, _} = Connection.uid_expunge(conn, "100:200")
    end
  end

  describe "tag generation" do
    test "tags increment sequentially" do
      {conn, socket} = start_connection()

      Mock.enqueue(socket, "A0001 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      # Check that the second command uses A0002
      Mock.enqueue(socket, "A0002 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      sent = Mock.get_sent(socket)
      assert Enum.at(sent, 0) =~ "A0001 NOOP"
      assert Enum.at(sent, 1) =~ "A0002 NOOP"
    end
  end

  describe "on_unsolicited_response callback" do
    defp start_connection_with_callback(callback) do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue(socket, "* OK IMAP4rev2 server ready\r\n")

      {:ok, conn} =
        Connection.start_link(
          transport: Mock,
          socket: socket,
          on_unsolicited_response: callback
        )

      {conn, socket}
    end

    defp select_mailbox(conn, socket, tag_offset) do
      login_tag = "A#{String.pad_leading(Integer.to_string(tag_offset), 4, "0")}"
      select_tag = "A#{String.pad_leading(Integer.to_string(tag_offset + 1), 4, "0")}"

      Mock.enqueue(socket, "#{login_tag} OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\n#{select_tag} OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
    end

    test "callback fires for EXISTS during a command" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      select_mailbox(conn, socket, 1)

      Mock.enqueue(socket, "* 11 EXISTS\r\nA0003 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Mailbox.Exists{count: 11}}
    end

    test "callback fires for EXPUNGE during a command" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      select_mailbox(conn, socket, 1)

      Mock.enqueue(socket, "* 3 EXPUNGE\r\nA0003 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Message.Expunge{seq: 3}}
    end

    test "callback fires for FETCH (FLAGS) during a command" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      select_mailbox(conn, socket, 1)

      Mock.enqueue(socket, "* 5 FETCH (FLAGS (\\Seen))\r\nA0003 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Message.Fetch{seq: 5}}
    end

    test "callback fires for FLAGS during a command" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      select_mailbox(conn, socket, 1)

      # Drain the EXISTS from SELECT
      assert_receive {:unsolicited, %Plover.Response.Mailbox.Exists{count: 10}}, 1000

      Mock.enqueue(
        socket,
        "* FLAGS (\\Seen \\Answered)\r\nA0003 OK NOOP completed\r\n"
      )

      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Mailbox.Flags{flags: flags}}
      assert :seen in flags
      assert :answered in flags
    end

    test "callback fires for LIST during a command" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")

      Mock.enqueue(
        socket,
        "* LIST (\\HasNoChildren) \"/\" \"NewFolder\"\r\nA0002 OK NOOP completed\r\n"
      )

      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Mailbox.List{name: "NewFolder"}}
    end

    test "no callback — existing behavior unchanged" do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")

      Mock.enqueue(socket, "* 11 EXISTS\r\nA0003 OK NOOP completed\r\n")
      assert {:ok, _} = Connection.noop(conn)
    end

    test "callback works through Plover.connect" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue(socket, "* OK IMAP4rev2 server ready\r\n")

      {:ok, conn} =
        Plover.connect("imap.example.com", 993,
          transport: Mock,
          socket: socket,
          on_unsolicited_response: callback
        )

      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")

      # Drain the EXISTS from SELECT
      assert_receive {:unsolicited, %Plover.Response.Mailbox.Exists{count: 10}}, 1000

      Mock.enqueue(socket, "* 15 EXISTS\r\nA0003 OK NOOP completed\r\n")
      {:ok, _} = Plover.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Mailbox.Exists{count: 15}}
    end

    test "callback fires for unrecognized untagged response" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")

      Mock.enqueue(socket, "* XEXTENSION some data\r\nA0002 OK NOOP completed\r\n")
      {:ok, _} = Connection.noop(conn)

      assert_received {:unsolicited, %Plover.Response.Unhandled{tokens: tokens}}
      assert is_list(tokens)
    end

    test "not invoked during IDLE" do
      parent = self()
      callback = fn response -> send(parent, {:unsolicited, response}) end

      {conn, socket} = start_connection_with_callback(callback)
      select_mailbox(conn, socket, 1)

      # Drain the EXISTS from SELECT
      assert_receive {:unsolicited, %Plover.Response.Mailbox.Exists{count: 10}}, 1000

      # Enter IDLE
      Mock.enqueue(socket, "+ idling\r\n")
      idle_callback = fn response -> send(parent, {:idle_update, response}) end
      assert :ok = Connection.idle(conn, idle_callback)

      # Server sends EXISTS during IDLE — idle callback fires, not unsolicited
      Mock.enqueue(socket, "* 12 EXISTS\r\n")
      Mock.setopts(socket, active: :once)

      assert_receive {:idle_update, %Plover.Response.Mailbox.Exists{count: 12}}, 1000
      refute_received {:unsolicited, _}

      # Stop idle — tag matches the IDLE command (A0003)
      Mock.enqueue(socket, "A0003 OK IDLE terminated\r\n")
      assert {:ok, _} = Connection.idle_done(conn)
    end
  end

  describe "EXPUNGE command" do
    setup do
      {conn, socket} = start_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Connection.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Connection.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "expunge messages", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 3 EXPUNGE\r\n* 3 EXPUNGE\r\nA0003 OK EXPUNGE completed\r\n"
      )

      assert {:ok, _} = Connection.expunge(conn)
    end
  end
end
