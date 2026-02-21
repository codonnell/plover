defmodule Plover.Connection.PendingOrderTest do
  use ExUnit.Case, async: true

  alias Plover.Connection
  alias Plover.Transport.Mock
  alias Plover.Response.{Capability, Mailbox, Message}

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
    {:ok, conn} = Connection.start_link(transport: Mock, socket: socket)

    Mock.enqueue_response(socket, :ok,
      code: %Capability{capabilities: ["IMAP4rev2"]},
      text: "LOGIN completed"
    )

    {:ok, _} = Connection.login(conn, "user", "pass")

    Mock.enqueue_response(socket, :ok,
      untagged: [
        %Mailbox.Exists{count: 10},
        %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
      ],
      code: {:read_write, nil},
      text: "SELECT completed"
    )

    {:ok, _} = Connection.select(conn, "INBOX")
    {conn, socket}
  end

  describe "pipelined command ordering" do
    test "concurrent UID FETCH commands get correct responses attributed" do
      {conn, socket} = setup_selected()

      # Enqueue two responses for two pipelined UID FETCH commands.
      # A0003 is for the first command, A0004 for the second.
      # Each response carries a different FETCH result so we can verify
      # the correct caller gets the correct response.
      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 1, attrs: %{uid: 100, flags: [:seen]}}
        ],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 2, attrs: %{uid: 200, flags: [:flagged]}}
        ],
        text: "FETCH completed"
      )

      # Fire both commands concurrently via Task
      task1 = Task.async(fn -> Connection.uid_fetch(conn, "100", [:uid, :flags]) end)
      task2 = Task.async(fn -> Connection.uid_fetch(conn, "200", [:uid, :flags]) end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      # First caller (task1) should get UID 100
      assert {:ok, [%Message.Fetch{attrs: %{uid: 100, flags: [:seen]}}]} = result1
      # Second caller (task2) should get UID 200
      assert {:ok, [%Message.Fetch{attrs: %{uid: 200, flags: [:flagged]}}]} = result2
    end

    test "three pipelined commands all succeed with correct response count" do
      {conn, socket} = setup_selected()

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 1, attrs: %{uid: 10, flags: [:seen]}}
        ],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 2, attrs: %{uid: 20, flags: [:flagged]}}
        ],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 3, attrs: %{uid: 30, flags: [:draft]}}
        ],
        text: "FETCH completed"
      )

      task1 = Task.async(fn -> Connection.uid_fetch(conn, "10", [:uid, :flags]) end)
      task2 = Task.async(fn -> Connection.uid_fetch(conn, "20", [:uid, :flags]) end)
      task3 = Task.async(fn -> Connection.uid_fetch(conn, "30", [:uid, :flags]) end)

      results = [Task.await(task1), Task.await(task2), Task.await(task3)]

      # All three should succeed and each should have exactly one fetch response
      uids =
        results
        |> Enum.map(fn {:ok, [%Message.Fetch{attrs: attrs}]} -> attrs.uid end)
        |> Enum.sort()

      assert uids == [10, 20, 30]
    end
  end
end
