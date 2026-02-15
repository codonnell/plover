defmodule Plover.Integration.AppendFlowTest do
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

  test "APPEND message to mailbox" do
    {conn, socket} = setup_authenticated()

    message = "From: user@example.com\r\nTo: friend@example.com\r\nSubject: Test\r\n\r\nHello!"

    # Server sends continuation after receiving literal size, then OK after literal
    Mock.enqueue(socket, "+ Ready for literal data\r\n")
    Mock.enqueue(socket, "A0002 OK [APPENDUID 38505 4001] APPEND completed\r\n")

    assert {:ok, resp} = Plover.append(conn, "INBOX", message)
    assert resp.status == :ok
    assert resp.code == {:append_uid, {38505, 4001}}

    # Verify the command was sent with proper literal syntax
    sent = Mock.get_sent(socket)
    append_cmd = Enum.find(sent, &String.contains?(&1, "APPEND"))
    size = byte_size(message)
    assert append_cmd =~ "APPEND INBOX {#{size}}"

    # Verify the literal data was sent
    assert (message <> "\r\n") in sent
  end

  test "APPEND with flags and date" do
    {conn, socket} = setup_authenticated()

    message = "Subject: Saved\r\n\r\nBody"

    Mock.enqueue(socket, "+ OK\r\n")
    Mock.enqueue(socket, "A0002 OK APPEND completed\r\n")

    assert {:ok, _} =
             Plover.append(conn, "Drafts", message,
               flags: [:seen, :draft],
               date: "14-Jul-2023 02:44:25 -0700"
             )

    sent = Mock.get_sent(socket)
    append_cmd = Enum.find(sent, &String.contains?(&1, "APPEND"))
    assert append_cmd =~ "APPEND Drafts"
    assert append_cmd =~ "(\\Seen \\Draft)"
    assert append_cmd =~ "\"14-Jul-2023 02:44:25 -0700\""
  end
end
