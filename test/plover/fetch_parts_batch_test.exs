defmodule Plover.FetchPartsBatchTest do
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

  defp text_part(charset \\ "UTF-8") do
    %BodyStructure{
      type: "TEXT",
      subtype: "PLAIN",
      params: %{"CHARSET" => charset},
      encoding: "BASE64",
      size: 0
    }
  end

  describe "fetch_parts_batch/3" do
    test "fetches multiple UIDs and returns decoded parts keyed by UID" do
      {conn, socket} = setup_selected()

      text1 = "Hello from UID 100"
      raw1 = Base.encode64(text1)

      text2 = "Hello from UID 200"
      raw2 = Base.encode64(text2)

      # Enqueue responses for both UID FETCH commands
      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 100, body: %{"1" => raw1}}}],
        text: "FETCH completed"
      )

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 2, attrs: %{uid: 200, body: %{"1" => raw2}}}],
        text: "FETCH completed"
      )

      parts_by_uid = [
        {"100", [{"1", text_part()}]},
        {"200", [{"1", text_part()}]}
      ]

      assert {:ok, result} = Plover.fetch_parts_batch(conn, parts_by_uid)
      assert map_size(result) == 2
      assert result["100"] == {:ok, [{"1", text1}]}
      assert result["200"] == {:ok, [{"1", text2}]}
    end

    test "empty input returns ok with empty map" do
      {conn, _socket} = setup_selected()

      assert {:ok, %{}} = Plover.fetch_parts_batch(conn, [])
    end

    test "single UID batch works" do
      {conn, socket} = setup_selected()

      text = "Single UID content"
      raw = Base.encode64(text)

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 42, body: %{"1" => raw}}}],
        text: "FETCH completed"
      )

      parts_by_uid = [{"42", [{"1", text_part()}]}]

      assert {:ok, result} = Plover.fetch_parts_batch(conn, parts_by_uid)
      assert result["42"] == {:ok, [{"1", text}]}
    end

    test "server error is reported per-UID, not as batch failure" do
      {conn, socket} = setup_selected()

      text = "Good content"
      raw = Base.encode64(text)

      # First UID succeeds
      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 100, body: %{"1" => raw}}}],
        text: "FETCH completed"
      )

      # Second UID fails
      Mock.enqueue_response(socket, :no, text: "FETCH failed")

      parts_by_uid = [
        {"100", [{"1", text_part()}]},
        {"200", [{"1", text_part()}]}
      ]

      assert {:ok, result} = Plover.fetch_parts_batch(conn, parts_by_uid)
      assert {:ok, [{"1", ^text}]} = result["100"]
      assert {:error, %Plover.Response.Tagged{status: :no}} = result["200"]
    end

    test "accepts max_concurrency option" do
      {conn, socket} = setup_selected()

      text = "Content"
      raw = Base.encode64(text)

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{uid: 100, body: %{"1" => raw}}}],
        text: "FETCH completed"
      )

      parts_by_uid = [{"100", [{"1", text_part()}]}]

      assert {:ok, result} = Plover.fetch_parts_batch(conn, parts_by_uid, max_concurrency: 1)
      assert result["100"] == {:ok, [{"1", text}]}
    end

    test "multiple parts per UID" do
      {conn, socket} = setup_selected()

      text_plain = "Plain text"
      text_html = "<p>HTML</p>"
      raw_plain = Base.encode64(text_plain)
      raw_html = Base.encode64(text_html)

      html_part = %BodyStructure{
        type: "TEXT",
        subtype: "HTML",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "BASE64",
        size: 0
      }

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{
            seq: 1,
            attrs: %{uid: 100, body: %{"1.1" => raw_plain, "1.2" => raw_html}}
          }
        ],
        text: "FETCH completed"
      )

      parts_by_uid = [{"100", [{"1.1", text_part()}, {"1.2", html_part}]}]

      assert {:ok, result} = Plover.fetch_parts_batch(conn, parts_by_uid)
      assert {:ok, [{"1.1", ^text_plain}, {"1.2", ^text_html}]} = result["100"]
    end
  end
end
