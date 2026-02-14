defmodule Plover.Integration.FetchFlowTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK Server ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")
    Mock.enqueue(socket, "* 100 EXISTS\r\nA0002 OK SELECT completed\r\n")
    {:ok, _} = Plover.select(conn, "INBOX")
    {conn, socket}
  end

  test "fetch multiple messages with flags and UID" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 1 FETCH (FLAGS (\\Seen) UID 100)\r\n" <>
        "* 2 FETCH (FLAGS (\\Seen \\Flagged) UID 101)\r\n" <>
        "* 3 FETCH (FLAGS () UID 102)\r\n" <>
        "* 4 FETCH (FLAGS (\\Answered \\Seen) UID 103)\r\n" <>
        "* 5 FETCH (FLAGS (\\Draft) UID 104)\r\n" <>
        "A0003 OK FETCH completed\r\n"
    )

    assert {:ok, messages} = Plover.fetch(conn, "1:5", [:flags, :uid])
    assert length(messages) == 5

    # Verify first message
    msg1 = hd(messages)
    assert msg1.seq == 1
    assert msg1.attrs.uid == 100
    assert :seen in msg1.attrs.flags

    # Verify unread message (no flags)
    msg3 = Enum.at(messages, 2)
    assert msg3.attrs.uid == 102
    assert msg3.attrs.flags == []

    # Verify flagged message
    msg2 = Enum.at(messages, 1)
    assert :flagged in msg2.attrs.flags
  end

  test "fetch envelope data" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 1 FETCH (ENVELOPE (\"Mon, 7 Feb 1994 21:52:25 -0800\" \"Meeting Tomorrow\" " <>
        "((\"John Doe\" NIL \"john\" \"example.com\")) " <>
        "((\"John Doe\" NIL \"john\" \"example.com\")) " <>
        "((\"John Doe\" NIL \"john\" \"example.com\")) " <>
        "((\"Jane Smith\" NIL \"jane\" \"example.com\")(\"Bob\" NIL \"bob\" \"example.com\")) " <>
        "NIL NIL NIL " <>
        "\"<B27397-0100000@example.com>\"))\r\n" <>
        "A0003 OK FETCH completed\r\n"
    )

    assert {:ok, [msg]} = Plover.fetch(conn, "1", [:envelope])
    env = msg.attrs.envelope
    assert env.subject == "Meeting Tomorrow"
    assert env.date == "Mon, 7 Feb 1994 21:52:25 -0800"
    assert length(env.from) == 1
    assert hd(env.from).mailbox == "john"
    assert length(env.to) == 2
    assert env.message_id == "<B27397-0100000@example.com>"
  end

  test "fetch body content with literal" do
    {conn, socket} = setup_selected()

    body_data = "Subject: Test\r\n\r\nHello World!"
    size = byte_size(body_data)

    Mock.enqueue(
      socket,
      "* 1 FETCH (BODY[] {#{size}}\r\n#{body_data})\r\nA0003 OK FETCH completed\r\n"
    )

    assert {:ok, [msg]} = Plover.fetch(conn, "1", [{:body, ""}])
    assert msg.attrs.body[""] == body_data
  end

  test "uid fetch" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 42 FETCH (UID 500 FLAGS (\\Seen) RFC822.SIZE 12345)\r\n" <>
        "A0003 OK UID FETCH completed\r\n"
    )

    assert {:ok, [msg]} = Plover.uid_fetch(conn, "500", [:flags, :rfc822_size])
    assert msg.attrs.uid == 500
    assert msg.attrs.rfc822_size == 12345
    assert :seen in msg.attrs.flags
  end
end
