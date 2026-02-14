defmodule PloverTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  # Helper: set up a connected, authenticated, selected connection via Plover API
  defp setup_connection do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK [CAPABILITY IMAP4rev2 AUTH=PLAIN IDLE] Ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    {conn, socket}
  end

  describe "connect/2 and connect/3" do
    test "connects and receives greeting" do
      {conn, _socket} = setup_connection()
      assert Process.alive?(conn)
    end
  end

  describe "login/3" do
    test "logs in with username and password" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      assert {:ok, _} = Plover.login(conn, "user", "password")
    end
  end

  describe "authenticate/3" do
    test "authenticates with PLAIN mechanism" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK AUTHENTICATE completed\r\n")
      assert {:ok, _} = Plover.authenticate(conn, "user@example.com", "password")
    end
  end

  describe "authenticate_xoauth2/3" do
    test "authenticates with XOAUTH2" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK AUTHENTICATE completed\r\n")
      assert {:ok, _} = Plover.authenticate_xoauth2(conn, "user@example.com", "oauth_token")
    end
  end

  describe "select/2" do
    test "selects mailbox" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")

      Mock.enqueue(socket, "* 172 EXISTS\r\n* FLAGS (\\Seen)\r\nA0002 OK [READ-WRITE] SELECT completed\r\n")
      assert {:ok, _} = Plover.select(conn, "INBOX")
    end
  end

  describe "list/3" do
    test "lists mailboxes" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")

      Mock.enqueue(
        socket,
        "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren) \"/\" \"Sent\"\r\nA0002 OK LIST completed\r\n"
      )

      assert {:ok, mailboxes} = Plover.list(conn, "", "*")
      assert length(mailboxes) == 2
    end
  end

  describe "fetch/3" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 5 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "fetches messages", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (FLAGS (\\Seen) UID 100)\r\nA0003 OK FETCH completed\r\n"
      )

      assert {:ok, [msg]} = Plover.fetch(conn, "1", [:flags, :uid])
      assert msg.attrs.uid == 100
    end
  end

  describe "search/2" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "searches messages", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* ESEARCH (TAG \"A0003\") UID COUNT 5\r\nA0003 OK SEARCH completed\r\n"
      )

      assert {:ok, esearch} = Plover.search(conn, "UNSEEN")
      assert esearch.count == 5
    end
  end

  describe "store/4" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 5 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "stores flags", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (FLAGS (\\Seen \\Deleted))\r\nA0003 OK STORE completed\r\n"
      )

      assert {:ok, _} = Plover.store(conn, "1", :add, [:deleted])
    end
  end

  describe "logout/1" do
    test "logs out and stops connection" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "* BYE server logging out\r\nA0001 OK LOGOUT completed\r\n")
      assert {:ok, _} = Plover.logout(conn)
      refute Process.alive?(conn)
    end
  end

  describe "noop/1" do
    test "sends noop" do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK NOOP completed\r\n")
      assert {:ok, _} = Plover.noop(conn)
    end
  end

  describe "status/3" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      %{conn: conn, socket: socket}
    end

    test "gets mailbox status", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* STATUS \"INBOX\" (MESSAGES 42 UNSEEN 3)\r\nA0002 OK STATUS completed\r\n"
      )

      assert {:ok, status} = Plover.status(conn, "INBOX", [:messages, :unseen])
      assert status.messages == 42
      assert status.unseen == 3
    end
  end

  describe "copy/3 and move/3" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "copies messages", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK COPY completed\r\n")
      assert {:ok, _} = Plover.copy(conn, "1:3", "Archive")
    end

    test "moves messages", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK MOVE completed\r\n")
      assert {:ok, _} = Plover.move(conn, "1:3", "Trash")
    end
  end

  describe "UID variants" do
    setup do
      {conn, socket} = setup_connection()
      Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
      {:ok, _} = Plover.login(conn, "user", "pass")
      Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
      {:ok, _} = Plover.select(conn, "INBOX")
      %{conn: conn, socket: socket}
    end

    test "uid fetch", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* 1 FETCH (UID 100 FLAGS (\\Seen))\r\nA0003 OK UID FETCH completed\r\n"
      )

      assert {:ok, [msg]} = Plover.uid_fetch(conn, "100", [:flags])
      assert msg.attrs.uid == 100
    end

    test "uid search", %{conn: conn, socket: socket} do
      Mock.enqueue(
        socket,
        "* ESEARCH (TAG \"A0003\") UID COUNT 5\r\nA0003 OK UID SEARCH completed\r\n"
      )

      assert {:ok, esearch} = Plover.uid_search(conn, "ALL")
      assert esearch.count == 5
    end

    test "uid store", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID STORE completed\r\n")
      assert {:ok, _} = Plover.uid_store(conn, "100", :add, [:seen])
    end

    test "uid copy", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID COPY completed\r\n")
      assert {:ok, _} = Plover.uid_copy(conn, "100:200", "Archive")
    end

    test "uid move", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID MOVE completed\r\n")
      assert {:ok, _} = Plover.uid_move(conn, "100:200", "Trash")
    end

    test "uid expunge", %{conn: conn, socket: socket} do
      Mock.enqueue(socket, "A0003 OK UID EXPUNGE completed\r\n")
      assert {:ok, _} = Plover.uid_expunge(conn, "100:200")
    end
  end
end
