defmodule Plover.Integration.IdleFlowTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK [CAPABILITY IMAP4rev2 IDLE] Server ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")
    Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
    {:ok, _} = Plover.select(conn, "INBOX")
    {conn, socket}
  end

  test "IDLE receives EXISTS update and exits cleanly" do
    {conn, socket} = setup_selected()

    # Server sends continuation to acknowledge IDLE
    Mock.enqueue(socket, "+ idling\r\n")

    parent = self()

    callback = fn response ->
      send(parent, {:idle_update, response})
    end

    # Enter IDLE mode
    assert :ok = Plover.idle(conn, callback)

    # Verify IDLE command was sent
    sent = Mock.get_sent(socket)
    idle_cmd = Enum.find(sent, &String.contains?(&1, "IDLE"))
    assert idle_cmd =~ "IDLE"

    # Server sends an update during IDLE
    Mock.enqueue(socket, "* 11 EXISTS\r\n")
    Mock.setopts(socket, active: :once)

    assert_receive {:idle_update, update}, 1000
    assert update.count == 11

    # Exit IDLE - tag matches the original IDLE command (A0003)
    Mock.enqueue(socket, "A0003 OK IDLE terminated\r\n")
    assert {:ok, _} = Plover.idle_done(conn)

    # Verify DONE was sent
    sent = Mock.get_sent(socket)
    assert "DONE\r\n" in sent
  end

  test "IDLE receives EXPUNGE during idle" do
    {conn, socket} = setup_selected()

    Mock.enqueue(socket, "+ idling\r\n")

    parent = self()
    callback = fn response -> send(parent, {:idle_update, response}) end

    assert :ok = Plover.idle(conn, callback)

    # Server notifies about expunged message
    Mock.enqueue(socket, "* 3 EXPUNGE\r\n")
    Mock.setopts(socket, active: :once)

    assert_receive {:idle_update, update}, 1000
    assert update.seq == 3

    Mock.enqueue(socket, "A0003 OK IDLE terminated\r\n")
    assert {:ok, _} = Plover.idle_done(conn)
  end
end
