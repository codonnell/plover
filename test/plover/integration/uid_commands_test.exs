defmodule Plover.Integration.UidCommandsTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK Server ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")
    Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
    {:ok, _} = Plover.select(conn, "INBOX")
    {conn, socket}
  end

  test "UID STORE adds flags" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 1 FETCH (FLAGS (\\Seen \\Deleted) UID 100)\r\n" <>
        "A0003 OK UID STORE completed\r\n"
    )

    assert {:ok, _} = Plover.uid_store(conn, "100", :add, [:deleted])

    sent = Mock.get_sent(socket)
    store_cmd = Enum.find(sent, &String.contains?(&1, "UID STORE"))
    assert store_cmd =~ "UID STORE 100 +FLAGS (\\Deleted)"
  end

  test "UID COPY copies messages" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "A0003 OK [COPYUID 38505 100:102 3956:3958] UID COPY completed\r\n"
    )

    assert {:ok, resp} = Plover.uid_copy(conn, "100:102", "Archive")
    assert resp.code == {:copy_uid, {38505, "100:102", "3956:3958"}}
  end

  test "UID MOVE moves messages" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n" <>
        "A0003 OK UID MOVE completed\r\n"
    )

    assert {:ok, _} = Plover.uid_move(conn, "100:102", "Trash")

    sent = Mock.get_sent(socket)
    move_cmd = Enum.find(sent, &String.contains?(&1, "UID MOVE"))
    assert move_cmd =~ "UID MOVE 100:102 Trash"
  end

  test "UID EXPUNGE removes specific messages" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 3 EXPUNGE\r\n* 5 EXPUNGE\r\n" <>
        "A0003 OK UID EXPUNGE completed\r\n"
    )

    assert {:ok, _} = Plover.uid_expunge(conn, "100,200")
  end
end
