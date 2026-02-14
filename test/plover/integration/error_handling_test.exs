defmodule Plover.Integration.ErrorHandlingTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_connection do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK Server ready\r\n")
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    {conn, socket}
  end

  test "NO response returns error tuple" do
    {conn, socket} = setup_connection()
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")

    Mock.enqueue(socket, "A0002 NO [NONEXISTENT] Mailbox not found\r\n")
    assert {:error, resp} = Plover.select(conn, "NonexistentMailbox")
    assert resp.status == :no
    assert resp.code == {:nonexistent, nil}
  end

  test "BAD response returns error tuple" do
    {conn, socket} = setup_connection()

    Mock.enqueue(socket, "A0001 BAD Command syntax error\r\n")
    assert {:error, resp} = Plover.login(conn, "user", "pass")
    assert resp.status == :bad
  end

  test "LOGIN failure preserves not_authenticated state" do
    {conn, socket} = setup_connection()

    Mock.enqueue(socket, "A0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
    {:error, _} = Plover.login(conn, "user", "wrong")
    assert Plover.Connection.state(conn) == :not_authenticated

    # Can try again
    Mock.enqueue(socket, "A0002 OK LOGIN completed\r\n")
    assert {:ok, _} = Plover.login(conn, "user", "correct")
    assert Plover.Connection.state(conn) == :authenticated
  end

  test "TRYCREATE hint on copy failure" do
    {conn, socket} = setup_connection()
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    {:ok, _} = Plover.login(conn, "user", "pass")
    Mock.enqueue(socket, "* 10 EXISTS\r\nA0002 OK SELECT completed\r\n")
    {:ok, _} = Plover.select(conn, "INBOX")

    # RFC 9051: COPY to non-existent mailbox
    Mock.enqueue(socket, "A0003 NO [TRYCREATE] Mailbox does not exist\r\n")
    assert {:error, resp} = Plover.copy(conn, "1:3", "NewFolder")
    assert resp.code == {:try_create, nil}
  end
end
