defmodule Plover.FetchPartsTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock
  alias Plover.Response.{BodyStructure, Mailbox, Message}

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)

    Mock.enqueue_response(socket, :ok,
      code: {:capability, ["IMAP4rev2"]},
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

  describe "fetch_parts/3" do
    test "fetches and decodes a single text part with charset conversion" do
      {conn, socket} = setup_selected()

      text = "Hello, World!"
      raw = Base.encode64(text)

      part = %BodyStructure{
        type: "TEXT",
        subtype: "PLAIN",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "BASE64",
        size: byte_size(raw)
      }

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{body: %{"1" => raw}}}],
        text: "FETCH completed"
      )

      assert {:ok, [{"1", decoded}]} = Plover.fetch_parts(conn, "100", [{"1", part}])
      assert decoded == text
    end

    test "fetches multiple parts with different encodings, preserves order" do
      {conn, socket} = setup_selected()

      # Part 1: quoted-printable ISO-8859-1 (é = 0xE9 in Latin-1)
      qp_raw = "caf=E9"

      qp_part = %BodyStructure{
        type: "TEXT",
        subtype: "PLAIN",
        params: %{"CHARSET" => "ISO-8859-1"},
        encoding: "QUOTED-PRINTABLE",
        size: byte_size(qp_raw)
      }

      # Part 2: base64 UTF-8
      b64_text = "Hello"
      b64_raw = Base.encode64(b64_text)

      b64_part = %BodyStructure{
        type: "TEXT",
        subtype: "HTML",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "BASE64",
        size: byte_size(b64_raw)
      }

      Mock.enqueue_response(socket, :ok,
        untagged: [
          %Message.Fetch{
            seq: 1,
            attrs: %{body: %{"1.1" => qp_raw, "1.2" => b64_raw}}
          }
        ],
        text: "FETCH completed"
      )

      parts = [{"1.1", qp_part}, {"1.2", b64_part}]
      assert {:ok, decoded} = Plover.fetch_parts(conn, "100", parts)
      assert [{"1.1", text1}, {"1.2", text2}] = decoded
      assert text1 == "café"
      assert text2 == "Hello"
    end

    test "binary parts get transfer decoding only, no charset conversion" do
      {conn, socket} = setup_selected()

      pdf_bytes = <<0x25, 0x50, 0x44, 0x46>>
      raw = Base.encode64(pdf_bytes)

      part = %BodyStructure{
        type: "APPLICATION",
        subtype: "PDF",
        params: %{"NAME" => "report.pdf"},
        encoding: "BASE64",
        size: byte_size(raw)
      }

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{body: %{"2" => raw}}}],
        text: "FETCH completed"
      )

      assert {:ok, [{"2", decoded}]} = Plover.fetch_parts(conn, "100", [{"2", part}])
      assert decoded == pdf_bytes
    end

    test "propagates fetch errors" do
      {conn, socket} = setup_selected()

      part = %BodyStructure{
        type: "TEXT",
        subtype: "PLAIN",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "7BIT",
        size: 100
      }

      Mock.enqueue_response(socket, :no, text: "FETCH failed")

      assert {:error, _} = Plover.fetch_parts(conn, "100", [{"1", part}])
    end

    test "returns error when a part has invalid encoding" do
      {conn, socket} = setup_selected()

      invalid_b64 = "this!!!not-base64"

      part = %BodyStructure{
        type: "TEXT",
        subtype: "PLAIN",
        params: %{"CHARSET" => "UTF-8"},
        encoding: "BASE64",
        size: byte_size(invalid_b64)
      }

      Mock.enqueue_response(socket, :ok,
        untagged: [%Message.Fetch{seq: 1, attrs: %{body: %{"1" => invalid_b64}}}],
        text: "FETCH completed"
      )

      assert {:error, _} = Plover.fetch_parts(conn, "100", [{"1", part}])
    end

    test "empty parts list returns ok with empty list" do
      {conn, _socket} = setup_selected()

      assert {:ok, []} = Plover.fetch_parts(conn, "100", [])
    end
  end
end
