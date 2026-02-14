defmodule Plover.Transport.MockTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock

  test "connect returns a mock socket" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    assert is_pid(socket)
  end

  test "send and receive data" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    # Enqueue data that the mock will "receive"
    Mock.enqueue(socket, "* OK IMAP4rev2 server ready\r\n")
    # Set active mode to get message
    :ok = Mock.setopts(socket, active: :once)
    assert_receive {:mock_ssl, ^socket, "* OK IMAP4rev2 server ready\r\n"}
  end

  test "send data to mock" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    :ok = Mock.send(socket, "A001 LOGIN user pass\r\n")
    # Verify the mock recorded what was sent
    assert Mock.get_sent(socket) == ["A001 LOGIN user pass\r\n"]
  end

  test "multiple enqueued messages delivered in order" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue(socket, "* OK greeting\r\n")
    Mock.enqueue(socket, "A001 OK done\r\n")

    :ok = Mock.setopts(socket, active: :once)
    assert_receive {:mock_ssl, ^socket, "* OK greeting\r\n"}

    :ok = Mock.setopts(socket, active: :once)
    assert_receive {:mock_ssl, ^socket, "A001 OK done\r\n"}
  end

  test "close the connection" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    :ok = Mock.close(socket)
    assert Process.alive?(socket) == false
  end

  test "controlling_process transfers ownership" do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    parent = self()
    Mock.enqueue(socket, "data\r\n")

    task = Task.async(fn ->
      receive do
        :take_over ->
          :ok = Mock.setopts(socket, active: :once)
          assert_receive {:mock_ssl, ^socket, "data\r\n"}
          send(parent, :received)
      end
    end)

    :ok = Mock.controlling_process(socket, task.pid)
    send(task.pid, :take_over)
    assert_receive :received, 1000
    Task.await(task)
  end
end
