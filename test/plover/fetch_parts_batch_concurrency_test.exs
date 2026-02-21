defmodule Plover.FetchPartsBatchConcurrencyTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock
  alias Plover.Response.{BodyStructure, Capability, Mailbox, Message}

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)

    Mock.enqueue_response(socket, :ok,
      code: %Capability{capabilities: ["IMAP4rev2"]},
      text: "LOGIN completed"
    )

    {:ok, _} = Plover.login(conn, "user", "pass")

    Mock.enqueue_response(socket, :ok,
      untagged: [
        %Mailbox.Exists{count: 10},
        %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
      ],
      code: {:read_write, nil},
      text: "SELECT completed"
    )

    {:ok, _} = Plover.select(conn, "INBOX")
    {conn, socket}
  end

  defp text_part do
    %BodyStructure{
      type: "TEXT",
      subtype: "PLAIN",
      params: %{"CHARSET" => "UTF-8"},
      encoding: "7BIT",
      size: 0
    }
  end

  describe "fetch_parts_batch/3 with max_concurrency < count" do
    test "returns results for all UIDs when count exceeds max_concurrency" do
      {conn, socket} = setup_selected()

      parts = [{"", text_part()}]

      parts_by_uid = [
        {"101", parts},
        {"102", parts},
        {"103", parts}
      ]

      # Enqueue a response for each UID FETCH command
      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 1, attrs: %{body: %{"" => "body one"}}}
        ],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 2, attrs: %{body: %{"" => "body two"}}}
        ],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{seq: 3, attrs: %{body: %{"" => "body three"}}}
        ],
        text: "FETCH completed"
      )

      # max_concurrency: 2 means the first 2 UIDs are fetched concurrently,
      # then the 3rd. This reproduces the bug where the third response gets
      # consumed and dropped before its command is sent.
      assert {:ok, results} =
               Plover.fetch_parts_batch(conn, parts_by_uid, max_concurrency: 2)

      assert map_size(results) == 3
      assert results["101"] == [{"", "body one"}]
      assert results["102"] == [{"", "body two"}]
      assert results["103"] == [{"", "body three"}]
    end
  end
end
