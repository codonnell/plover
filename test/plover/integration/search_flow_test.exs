defmodule Plover.Integration.SearchFlowTest do
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

  # RFC 9051 Section 7.3.4 - ESEARCH response
  test "search returns ESEARCH with MIN/MAX/COUNT" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* ESEARCH (TAG \"A0003\") UID MIN 1 MAX 500 COUNT 42\r\n" <>
        "A0003 OK SEARCH completed\r\n"
    )

    assert {:ok, esearch} = Plover.search(conn, "UNSEEN")
    assert esearch.uid == true
    assert esearch.min == 1
    assert esearch.max == 500
    assert esearch.count == 42
  end

  test "search with ALL result returns sequence set" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* ESEARCH (TAG \"A0003\") UID ALL 1:3,5,10:15\r\n" <>
        "A0003 OK SEARCH completed\r\n"
    )

    assert {:ok, esearch} = Plover.search(conn, "ALL")
    assert esearch.all == "1:3,5,10:15"
  end

  test "uid search" do
    {conn, socket} = setup_selected()

    Mock.enqueue(
      socket,
      "* ESEARCH (TAG \"A0003\") UID COUNT 0\r\n" <>
        "A0003 OK UID SEARCH completed\r\n"
    )

    assert {:ok, esearch} = Plover.uid_search(conn, "FROM \"nobody@example.com\"")
    assert esearch.count == 0
  end
end
