defmodule Plover.Integration.LoginFlowTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  defp setup_server do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])

    Mock.enqueue(
      socket,
      "* OK [CAPABILITY IMAP4rev2 AUTH=PLAIN AUTH=XOAUTH2 IDLE] Server ready\r\n"
    )

    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
    {conn, socket}
  end

  test "LOGIN flow: connect -> login -> logout" do
    {conn, socket} = setup_server()

    # Verify capabilities from greeting
    caps = Plover.Connection.capabilities(conn)
    assert "IMAP4rev2" in caps
    assert "AUTH=PLAIN" in caps

    # Login
    Mock.enqueue(socket, "A0001 OK [CAPABILITY IMAP4rev2 IDLE] LOGIN completed\r\n")
    assert {:ok, _} = Plover.login(conn, "user@example.com", "password123")
    assert Plover.Connection.state(conn) == :authenticated

    # Logout
    Mock.enqueue(socket, "* BYE server logging out\r\nA0002 OK LOGOUT completed\r\n")
    assert {:ok, _} = Plover.logout(conn)
    refute Process.alive?(conn)
  end

  test "AUTHENTICATE PLAIN flow" do
    {conn, socket} = setup_server()

    Mock.enqueue(socket, "A0001 OK [CAPABILITY IMAP4rev2] AUTHENTICATE completed\r\n")
    assert {:ok, _} = Plover.authenticate(conn, "user@example.com", "password123")
    assert Plover.Connection.state(conn) == :authenticated

    # Verify the sent command contains AUTHENTICATE PLAIN with base64
    sent = Mock.get_sent(socket)
    auth_cmd = Enum.find(sent, &String.contains?(&1, "AUTHENTICATE PLAIN"))
    assert auth_cmd != nil
    # Extract the base64 token
    [_, token] = Regex.run(~r/AUTHENTICATE PLAIN (\S+)/, auth_cmd)
    decoded = Base.decode64!(token)
    assert decoded == "\0user@example.com\0password123"
  end

  test "AUTHENTICATE XOAUTH2 flow" do
    {conn, socket} = setup_server()

    Mock.enqueue(socket, "A0001 OK AUTHENTICATE completed\r\n")
    assert {:ok, _} = Plover.authenticate_xoauth2(conn, "user@gmail.com", "ya29.oauth_token")
    assert Plover.Connection.state(conn) == :authenticated

    sent = Mock.get_sent(socket)
    auth_cmd = Enum.find(sent, &String.contains?(&1, "AUTHENTICATE XOAUTH2"))
    assert auth_cmd != nil
    [_, token] = Regex.run(~r/AUTHENTICATE XOAUTH2 (\S+)/, auth_cmd)
    decoded = Base.decode64!(token)
    assert decoded == "user=user@gmail.com\x01auth=Bearer ya29.oauth_token\x01\x01"
  end

  test "failed login attempt" do
    {conn, socket} = setup_server()

    Mock.enqueue(socket, "A0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
    assert {:error, resp} = Plover.login(conn, "user@example.com", "wrong_password")
    assert resp.status == :no
    assert resp.code == {:authentication_failed, nil}
    assert Plover.Connection.state(conn) == :not_authenticated
  end
end
