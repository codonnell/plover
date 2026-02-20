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

  test "UID COPY returns COPYUID map" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "A0003 OK [COPYUID 38505 100:102 3956:3958] UID COPY completed\r\n"
    )

    assert {:ok, resp} = Plover.uid_copy(conn, "100:102", "Archive")
    assert resp == %{uid_validity: 38505, source_uids: "100:102", dest_uids: "3956:3958"}
  end

  test "UID MOVE returns COPYUID map from untagged OK" do
    {conn, socket} = setup_selected()

    # Per RFC 9051 §6.4.8, MOVE sends COPYUID in an untagged OK before EXPUNGEs
    Mock.enqueue(
      socket,
      "* OK [COPYUID 432432 42:69 1202:1229]\r\n" <>
        "* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n" <>
        "A0003 OK UID MOVE completed\r\n"
    )

    assert {:ok, resp} = Plover.uid_move(conn, "42:69", "foo")
    assert resp == %{uid_validity: 432432, source_uids: "42:69", dest_uids: "1202:1229"}

    sent = Mock.get_sent(socket)
    move_cmd = Enum.find(sent, &String.contains?(&1, "UID MOVE"))
    assert move_cmd =~ "UID MOVE 42:69 foo"
  end

  test "COPY returns COPYUID map" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "A0003 OK [COPYUID 38505 304,319:320 3956:3958] COPY completed\r\n"
    )

    assert {:ok, resp} = Plover.copy(conn, "2:4", "meeting")
    assert resp == %{uid_validity: 38505, source_uids: "304,319:320", dest_uids: "3956:3958"}
  end

  test "COPY without COPYUID returns nil" do
    {conn, socket} = setup_selected()

    Mock.enqueue(socket, "A0003 OK COPY completed\r\n")

    assert {:ok, nil} = Plover.copy(conn, "2", "funny")
  end

  test "MOVE returns COPYUID map from untagged OK" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* OK [COPYUID 38505 100:102 3956:3958]\r\n" <>
        "* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n" <>
        "A0003 OK MOVE completed\r\n"
    )

    assert {:ok, resp} = Plover.move(conn, "1:3", "Archive")
    assert resp == %{uid_validity: 38505, source_uids: "100:102", dest_uids: "3956:3958"}
  end

  test "MOVE without COPYUID returns nil" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* 1 EXPUNGE\r\n" <>
        "A0003 OK MOVE completed\r\n"
    )

    assert {:ok, nil} = Plover.move(conn, "1", "Trash")
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
