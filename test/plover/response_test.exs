defmodule Plover.ResponseTest do
  use ExUnit.Case, async: true

  # RFC 9051 Section 7.1 - Tagged responses
  # tag SP ("OK" / "NO" / "BAD") SP resp-text CRLF
  describe "Tagged" do
    alias Plover.Response.Tagged

    test "creates a tagged OK response" do
      resp = %Tagged{tag: "A001", status: :ok, text: "SELECT completed"}
      assert resp.tag == "A001"
      assert resp.status == :ok
      assert resp.text == "SELECT completed"
      assert resp.code == nil
    end

    test "creates a tagged response with response code" do
      resp = %Tagged{tag: "A001", status: :ok, code: {:read_write, nil}, text: "SELECT completed"}
      assert resp.code == {:read_write, nil}
    end
  end

  # RFC 9051 Section 7.5 - Continuation request
  # "+" SP resp-text CRLF
  describe "Continuation" do
    alias Plover.Response.Continuation

    test "creates a continuation response" do
      resp = %Continuation{text: "ready for literal data"}
      assert resp.text == "ready for literal data"
      assert resp.base64 == nil
    end

    test "creates a continuation with base64 challenge" do
      resp = %Continuation{text: "", base64: "dXNlcg=="}
      assert resp.base64 == "dXNlcg=="
    end
  end

  # RFC 9051 Section 2.3.5 - Envelope
  describe "Envelope" do
    alias Plover.Response.Envelope
    alias Plover.Response.Address

    test "creates an envelope with all fields" do
      addr = %Address{name: "John Doe", adl: nil, mailbox: "john", host: "example.com"}

      env = %Envelope{
        date: "Mon, 7 Feb 1994 21:52:25 -0800",
        subject: "Test Subject",
        from: [addr],
        sender: [addr],
        reply_to: [addr],
        to: [addr],
        cc: [],
        bcc: [],
        in_reply_to: nil,
        message_id: "<test@example.com>"
      }

      assert env.subject == "Test Subject"
      assert hd(env.from).mailbox == "john"
    end
  end

  # RFC 9051 Section 2.3.6 - Address
  describe "Address" do
    alias Plover.Response.Address

    test "creates an address struct" do
      addr = %Address{name: "John Doe", adl: nil, mailbox: "john", host: "example.com"}
      assert addr.name == "John Doe"
      assert addr.mailbox == "john"
      assert addr.host == "example.com"
    end

    test "nil address represents end of group" do
      addr = %Address{name: nil, adl: nil, mailbox: nil, host: nil}
      assert addr.name == nil
    end
  end

  # RFC 9051 Section 2.3.6 - Body Structure
  describe "BodyStructure" do
    alias Plover.Response.BodyStructure

    test "creates a basic body structure" do
      bs = %BodyStructure{type: "text", subtype: "plain", params: %{"charset" => "utf-8"}}
      assert bs.type == "text"
      assert bs.subtype == "plain"
      assert bs.params["charset"] == "utf-8"
      assert bs.parts == []
    end

    test "creates a multipart body structure" do
      part1 = %BodyStructure{type: "text", subtype: "plain"}
      part2 = %BodyStructure{type: "text", subtype: "html"}
      bs = %BodyStructure{type: "multipart", subtype: "alternative", parts: [part1, part2]}
      assert length(bs.parts) == 2
    end
  end

  # RFC 9051 Section 7.3.4 - ESEARCH response
  describe "ESearch" do
    alias Plover.Response.ESearch

    test "creates an ESEARCH response" do
      resp = %ESearch{tag: "A001", uid: true, min: 1, max: 500, count: 42}
      assert resp.uid == true
      assert resp.min == 1
      assert resp.max == 500
      assert resp.count == 42
      assert resp.all == nil
    end
  end

  # Mailbox-related response data
  describe "Mailbox" do
    alias Plover.Response.Mailbox

    test "creates mailbox list entry" do
      # RFC 9051 Section 7.2.2 - LIST response
      mb = %Mailbox.List{
        flags: [:noselect, :has_children],
        delimiter: "/",
        name: "INBOX/Sent"
      }

      assert mb.delimiter == "/"
      assert :noselect in mb.flags
    end

    test "creates mailbox status" do
      # RFC 9051 Section 7.2.4 - STATUS response
      status = %Mailbox.Status{
        name: "INBOX",
        messages: 17,
        recent: 2,
        unseen: 5,
        uid_next: 4392,
        uid_validity: 3_857_529_045
      }

      assert status.messages == 17
      assert status.uid_next == 4392
    end

    test "creates mailbox flags" do
      flags = %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
      assert :seen in flags.flags
    end

    test "creates mailbox exists" do
      exists = %Mailbox.Exists{count: 172}
      assert exists.count == 172
    end
  end

  # Message-related response data
  describe "Message" do
    alias Plover.Response.Message

    test "creates a fetch response" do
      fetch = %Message.Fetch{
        seq: 12,
        attrs: %{
          flags: [:seen],
          uid: 4827,
          envelope: nil,
          body_structure: nil,
          body: nil,
          internal_date: nil
        }
      }

      assert fetch.seq == 12
      assert fetch.attrs.uid == 4827
    end

    test "creates an expunge response" do
      # RFC 9051 Section 7.5.1 - EXPUNGE response
      expunge = %Message.Expunge{seq: 3}
      assert expunge.seq == 3
    end
  end
end
