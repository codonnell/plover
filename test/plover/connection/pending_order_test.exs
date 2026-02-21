defmodule Plover.Connection.PendingOrderTest do
  use ExUnit.Case, async: true

  alias Plover.Connection
  alias Plover.Transport.Mock
  alias Plover.Response.{BodyStructure, Capability, Mailbox, Message}

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
    test "responses are attributed by tag order, not by task spawn order" do
      {conn, socket} = setup_selected()

      # Enqueue two responses for two pipelined UID FETCH commands.
      # Response 1 (tag A0003) carries UID 100, response 2 (tag A0004) carries UID 200.
      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 100, flags: [:seen]}}],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 2, attrs: %{uid: 200, flags: [:flagged]}}],
        text: "FETCH completed"
      )

      # Force a specific call order: process B calls the GenServer FIRST,
      # then process A. This guarantees B gets tag A0003 and A gets A0004.
      parent = self()

      pid_b =
        spawn_link(fn ->
          receive do
            :go -> :ok
          end

          result = Connection.uid_fetch(conn, "200", [:uid, :flags])
          send(parent, {:result_b, result})
        end)

      pid_a =
        spawn_link(fn ->
          receive do
            :go -> :ok
          end

          result = Connection.uid_fetch(conn, "100", [:uid, :flags])
          send(parent, {:result_a, result})
        end)

      # Release B first, give it time to enter GenServer.call
      send(pid_b, :go)
      Process.sleep(50)
      # Then release A
      send(pid_a, :go)

      result_b = receive do {:result_b, r} -> r after 5000 -> flunk("timeout waiting for B") end
      result_a = receive do {:result_a, r} -> r after 5000 -> flunk("timeout waiting for A") end

      # B called first → got tag A0003 → got response 1 (UID 100 data)
      # A called second → got tag A0004 → got response 2 (UID 200 data)
      # Responses are matched by tag, not by what the caller requested.
      assert {:ok, [%Message.Fetch{attrs: %{uid: 100}}]} = result_b
      assert {:ok, [%Message.Fetch{attrs: %{uid: 200}}]} = result_a
    end

    test "fetch_parts_batch preserves list-order-to-tag mapping" do
      {conn, socket} = setup_selected()

      text1 = "Content for UID 100"
      raw1 = Base.encode64(text1)
      text2 = "Content for UID 200"
      raw2 = Base.encode64(text2)

      part = %BodyStructure{
        type: "TEXT",
        subtype: "PLAIN",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "BASE64",
        size: 0
      }

      # Enqueue responses in list order: first for UID 100, second for UID 200
      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 100, body: %{"1" => raw1}}}],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 2, attrs: %{uid: 200, body: %{"1" => raw2}}}],
        text: "FETCH completed"
      )

      # fetch_parts_batch matches responses by UID, so each UID gets the correct content
      # regardless of how the server batches untagged responses.
      parts_by_uid = [
        {"100", [{"1", part}]},
        {"200", [{"1", part}]}
      ]

      assert {:ok, results} = Plover.fetch_parts_batch(conn, parts_by_uid)
      assert results["100"] == {:ok, [{"1", text1}]}
      assert results["200"] == {:ok, [{"1", text2}]}
    end

    test "three pipelined commands all succeed with correct response count" do
      {conn, socket} = setup_selected()

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 10, flags: [:seen]}}],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 2, attrs: %{uid: 20, flags: [:flagged]}}],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 3, attrs: %{uid: 30, flags: [:draft]}}],
        text: "FETCH completed"
      )

      task1 = Task.async(fn -> Connection.uid_fetch(conn, "10", [:uid, :flags]) end)
      task2 = Task.async(fn -> Connection.uid_fetch(conn, "20", [:uid, :flags]) end)
      task3 = Task.async(fn -> Connection.uid_fetch(conn, "30", [:uid, :flags]) end)

      results = [Task.await(task1), Task.await(task2), Task.await(task3)]

      # All three should succeed and each should have exactly one fetch response.
      # We don't assert which task gets which UID since Task scheduling is nondeterministic.
      uids =
        results
        |> Enum.map(fn {:ok, [%Message.Fetch{attrs: attrs}]} -> attrs.uid end)
        |> Enum.sort()

      assert uids == [10, 20, 30]
    end
  end
end
