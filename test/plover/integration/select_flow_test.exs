defmodule Plover.Integration.SelectFlowTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_authenticated do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK [CAPABILITY IMAP4rev2] Server ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")
    {conn, socket}
  end

  test "SELECT -> use -> CLOSE flow" do
    {conn, socket} = setup_authenticated()

    # SELECT INBOX with full server response
    # RFC 9051 Section 6.3.1 example
    Mock.enqueue(
      socket,
      "* 172 EXISTS\r\n" <>
        "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n" <>
        "* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n" <>
        "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n" <>
        "* OK [UIDNEXT 4392] Predicted next UID\r\n" <>
        "A0002 OK [READ-WRITE] SELECT completed\r\n"
    )

    assert {:ok, _} = Plover.select(conn, "INBOX")
    assert Plover.Connection.state(conn) == :selected

    # Verify mailbox info was captured
    info = Plover.Connection.mailbox_info(conn)
    assert info.exists == 172
    assert :seen in info.flags

    # CLOSE
    Mock.enqueue(socket, "A0003 OK CLOSE completed\r\n")
    assert {:ok, _} = Plover.close(conn)
    assert Plover.Connection.state(conn) == :authenticated
  end

  test "EXAMINE for read-only access" do
    {conn, socket} = setup_authenticated()

    Mock.enqueue(
      socket,
      "* 50 EXISTS\r\n" <>
        "* FLAGS (\\Seen)\r\n" <>
        "A0002 OK [READ-ONLY] EXAMINE completed\r\n"
    )

    assert {:ok, _} = Plover.examine(conn, "INBOX")
    assert Plover.Connection.state(conn) == :selected
  end

  test "LIST mailboxes" do
    {conn, socket} = setup_authenticated()

    Mock.enqueue(
      socket,
      "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n" <>
        "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"\r\n" <>
        "* LIST (\\HasNoChildren \\Drafts) \"/\" \"Drafts\"\r\n" <>
        "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"\r\n" <>
        "* LIST (\\HasChildren) \"/\" \"Work\"\r\n" <>
        "* LIST (\\HasNoChildren) \"/\" \"Work/Projects\"\r\n" <>
        "A0002 OK LIST completed\r\n"
    )

    assert {:ok, mailboxes} = Plover.list(conn, "", "*")
    assert length(mailboxes) == 6

    inbox = Enum.find(mailboxes, &(&1.name == "INBOX"))
    assert inbox != nil
    assert :has_no_children in inbox.flags

    work = Enum.find(mailboxes, &(&1.name == "Work"))
    assert :has_children in work.flags
  end

  test "STATUS check" do
    {conn, socket} = setup_authenticated()

    Mock.enqueue(
      socket,
      "* STATUS \"INBOX\" (MESSAGES 231 UIDNEXT 44292 UIDVALIDITY 1 UNSEEN 5)\r\n" <>
        "A0002 OK STATUS completed\r\n"
    )

    assert {:ok, status} = Plover.status(conn, "INBOX", [:messages, :uid_next, :uid_validity, :unseen])
    assert status.messages == 231
    assert status.uid_next == 44292
    assert status.uid_validity == 1
    assert status.unseen == 5
  end
end
