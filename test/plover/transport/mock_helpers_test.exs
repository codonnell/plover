defmodule Plover.Transport.MockHelpersTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock
  alias Plover.Response.Capability
  alias Plover.Response.Mailbox
  alias Plover.Response.Message

  describe "enqueue_greeting/2" do
    test "enqueues a server greeting with default capabilities" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "* OK [CAPABILITY IMAP4rev2]"
      assert String.ends_with?(line, "\r\n")
    end

    test "enqueues a greeting with custom text" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2", "IDLE"], text: "Ready")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "IMAP4rev2"
      assert line =~ "IDLE"
      assert line =~ "Ready"
    end

    test "enqueues a plain greeting without capabilities" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_greeting(socket, text: "Server ready")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "* OK"
      assert line =~ "Server ready"
    end

    test "does not increment tag counter" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_greeting(socket)

      # First response should still use A0001
      Mock.enqueue_response(socket, :ok, text: "LOGIN completed")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, _greeting}
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, resp_data}
      assert to_string(resp_data) =~ "A0001"
    end
  end

  describe "enqueue_response/3" do
    test "auto-generates sequential tags" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])

      Mock.enqueue_response(socket, :ok, text: "first")
      Mock.enqueue_response(socket, :ok, text: "second")
      Mock.enqueue_response(socket, :ok, text: "third")

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data1}
      assert to_string(data1) =~ "A0001 OK"

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data2}
      assert to_string(data2) =~ "A0002 OK"

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data3}
      assert to_string(data3) =~ "A0003 OK"
    end

    test "encodes NO response" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_response(socket, :no, text: "access denied")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      assert to_string(data) =~ "A0001 NO access denied"
    end

    test "encodes BAD response" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_response(socket, :bad, text: "invalid command")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      assert to_string(data) =~ "A0001 BAD invalid command"
    end

    test "includes response code" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])

      Mock.enqueue_response(socket, :ok,
        code: %Capability{capabilities: ["IMAP4rev2"]},
        text: "LOGIN completed"
      )

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "[CAPABILITY IMAP4rev2]"
      assert line =~ "LOGIN completed"
    end

    test "includes untagged responses before tagged" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Mailbox.Exists{count: 172},
          %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
        ],
        code: {:read_write, nil},
        text: "SELECT completed"
      )

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "* 172 EXISTS"
      assert line =~ "* FLAGS"
      assert line =~ "A0001 OK [READ-WRITE] SELECT completed"
    end

    test "includes fetch responses" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 1, attrs: %{flags: [:seen], uid: 100}},
          %Message.Fetch{seq: 2, attrs: %{flags: [:seen, :flagged], uid: 101}}
        ],
        text: "FETCH completed"
      )

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      line = to_string(data)
      assert line =~ "* 1 FETCH"
      assert line =~ "* 2 FETCH"
      assert line =~ "FETCH completed"
    end
  end

  describe "enqueue_continuation/2" do
    test "enqueues continuation response" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_continuation(socket, text: "Ready for literal data")
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      assert to_string(data) =~ "+ Ready for literal data"
    end

    test "enqueues empty continuation" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_continuation(socket)
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, data}
      assert to_string(data) == "+\r\n"
    end

    test "does not increment tag counter" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])
      Mock.enqueue_continuation(socket)
      Mock.enqueue_response(socket, :ok, text: "done")

      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, _cont}
      :ok = Mock.setopts(socket, active: :once)
      assert_receive {:mock_ssl, ^socket, resp}
      assert to_string(resp) =~ "A0001"
    end
  end

  describe "integration: full flow with new API" do
    test "connect → login → select → fetch" do
      {:ok, socket} = Mock.connect("imap.example.com", 993, [])

      # Greeting
      Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
      {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)

      # Login
      Mock.enqueue_response(socket, :ok,
        code: %Capability{capabilities: ["IMAP4rev2"]},
        text: "LOGIN completed"
      )

      {:ok, _} = Plover.login(conn, "user", "pass")

      # Select
      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Mailbox.Exists{count: 10},
          %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
        ],
        code: {:read_write, nil},
        text: "SELECT completed"
      )

      {:ok, _} = Plover.select(conn, "INBOX")

      # Fetch
      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 1, attrs: %{flags: [:seen], uid: 100}},
          %Message.Fetch{seq: 2, attrs: %{flags: [:seen, :flagged], uid: 101}}
        ],
        text: "FETCH completed"
      )

      {:ok, messages} = Plover.fetch(conn, "1:2", [:flags, :uid])
      assert length(messages) == 2
      [msg1, msg2] = messages
      assert msg1.attrs.uid == 100
      assert msg2.attrs.uid == 101
    end
  end
end
