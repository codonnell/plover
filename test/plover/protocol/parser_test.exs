defmodule Plover.Protocol.ParserTest do
  use ExUnit.Case, async: true

  alias Plover.Protocol.Parser
  alias Plover.Response.{Tagged, Continuation, Envelope, Address, BodyStructure, ESearch}
  alias Plover.Response.Mailbox
  alias Plover.Response.Message

  # Helper: tokenize then parse
  defp parse(input) do
    {:ok, tokens, _rest} = Plover.Protocol.Tokenizer.tokenize(input)
    Parser.parse(tokens)
  end

  # RFC 9051 Section 7.1 - Server Responses - Status Responses
  describe "tagged responses" do
    test "tagged OK response" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, text: "SELECT completed"}} =
               parse("A001 OK SELECT completed\r\n")
    end

    test "tagged NO response" do
      assert {:ok, %Tagged{tag: "A001", status: :no, text: "Mailbox not found"}} =
               parse("A001 NO Mailbox not found\r\n")
    end

    test "tagged BAD response" do
      assert {:ok, %Tagged{tag: "A001", status: :bad, text: "command unknown"}} =
               parse("A001 BAD command unknown\r\n")
    end

    test "tagged OK with response code" do
      # RFC 9051 Section 7.1: resp-text = ["[" resp-text-code "]" SP] [text]
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:read_write, nil}, text: "SELECT completed"}} =
               parse("A001 OK [READ-WRITE] SELECT completed\r\n")
    end

    test "tagged OK with UIDVALIDITY response code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:uid_validity, 3857529045}}} =
               parse("A001 OK [UIDVALIDITY 3857529045] UIDs valid\r\n")
    end

    test "tagged OK with UIDNEXT response code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:uid_next, 4392}}} =
               parse("A001 OK [UIDNEXT 4392] Predicted next UID\r\n")
    end

    test "tagged NO with AUTHENTICATIONFAILED code" do
      assert {:ok, %Tagged{tag: "A001", status: :no, code: {:authentication_failed, nil}}} =
               parse("A001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
    end

    test "tagged OK with CAPABILITY code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:capability, caps}}} =
               parse("A001 OK [CAPABILITY IMAP4rev2 AUTH=PLAIN] Logged in\r\n")

      assert "IMAP4rev2" in caps
      assert "AUTH=PLAIN" in caps
    end

    test "tagged OK with PERMANENTFLAGS code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:permanent_flags, flags}}} =
               parse("A001 OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n")

      assert :deleted in flags
      assert :seen in flags
      assert :wildcard in flags
    end

    test "tagged OK with READ-ONLY code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:read_only, nil}}} =
               parse("A001 OK [READ-ONLY] EXAMINE completed\r\n")
    end

    test "tagged OK with APPENDUID code" do
      # RFC 9051 Section 7.1: resp-code-apnd = "APPENDUID" SP nz-number SP append-uid
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:append_uid, {38505, 3955}}}} =
               parse("A001 OK [APPENDUID 38505 3955] APPEND completed\r\n")
    end

    test "tagged OK with COPYUID code" do
      # RFC 9051 Section 7.1: resp-code-copy = "COPYUID" SP nz-number SP uid-set SP uid-set
      assert {:ok, %Tagged{tag: "A003", status: :ok, code: {:copy_uid, {38505, "304,319:320", "3956:3958"}}}} =
               parse("A003 OK [COPYUID 38505 304,319:320 3956:3958] COPY completed\r\n")
    end

    test "tagged OK with CLOSED code" do
      assert {:ok, %Tagged{tag: "A001", status: :ok, code: {:closed, nil}}} =
               parse("A001 OK [CLOSED] Previous mailbox closed\r\n")
    end

    test "tagged NO with TRYCREATE code" do
      assert {:ok, %Tagged{tag: "A001", status: :no, code: {:try_create, nil}}} =
               parse("A001 NO [TRYCREATE] Mailbox doesn't exist\r\n")
    end
  end

  # RFC 9051 Section 7.5 - Continuation request
  describe "continuation responses" do
    test "continuation with text" do
      assert {:ok, %Continuation{text: "ready for literal data"}} =
               parse("+ ready for literal data\r\n")
    end

    test "continuation with empty text" do
      assert {:ok, %Continuation{text: ""}} = parse("+\r\n")
    end

    test "continuation with base64 challenge" do
      assert {:ok, %Continuation{text: "", base64: "dXNlcg=="}} =
               parse("+ dXNlcg==\r\n")
    end
  end

  # RFC 9051 Section 7.2.1 - CAPABILITY
  describe "untagged CAPABILITY" do
    test "parses capability list" do
      assert {:ok, {:capability, caps}} =
               parse("* CAPABILITY IMAP4rev2 AUTH=PLAIN AUTH=XOAUTH2 IDLE\r\n")

      assert "IMAP4rev2" in caps
      assert "AUTH=PLAIN" in caps
      assert "AUTH=XOAUTH2" in caps
      assert "IDLE" in caps
    end
  end

  # RFC 9051 Section 7.2.6 - FLAGS
  describe "untagged FLAGS" do
    test "parses flag list" do
      assert {:ok, %Mailbox.Flags{flags: flags}} =
               parse("* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n")

      assert :answered in flags
      assert :flagged in flags
      assert :deleted in flags
      assert :seen in flags
      assert :draft in flags
    end

    test "parses empty flag list" do
      assert {:ok, %Mailbox.Flags{flags: []}} = parse("* FLAGS ()\r\n")
    end

    test "parses flags with keyword flags" do
      assert {:ok, %Mailbox.Flags{flags: flags}} =
               parse("* FLAGS (\\Seen $Forwarded $MDNSent)\r\n")

      assert :seen in flags
      assert :"$Forwarded" in flags
      assert :"$MDNSent" in flags
    end
  end

  # RFC 9051 Section 7.3.1 - EXISTS
  describe "untagged EXISTS" do
    test "parses message count" do
      assert {:ok, %Mailbox.Exists{count: 172}} = parse("* 172 EXISTS\r\n")
    end

    test "parses zero messages" do
      assert {:ok, %Mailbox.Exists{count: 0}} = parse("* 0 EXISTS\r\n")
    end
  end

  # RFC 9051 Section 7.2.2 - LIST
  describe "untagged LIST" do
    test "parses LIST response" do
      assert {:ok, %Mailbox.List{flags: flags, delimiter: "/", name: "INBOX"}} =
               parse("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n")

      assert :has_no_children in flags
    end

    test "parses LIST with NIL delimiter" do
      assert {:ok, %Mailbox.List{delimiter: nil, name: "INBOX"}} =
               parse("* LIST () NIL INBOX\r\n")
    end

    test "parses LIST with multiple flags" do
      assert {:ok, %Mailbox.List{flags: flags, name: "Drafts"}} =
               parse("* LIST (\\HasNoChildren \\Drafts) \"/\" \"Drafts\"\r\n")

      assert :has_no_children in flags
      assert :drafts in flags
    end

    test "parses LIST with \\Noselect flag" do
      assert {:ok, %Mailbox.List{flags: flags, name: "Public Folders"}} =
               parse("* LIST (\\Noselect \\HasChildren) \"/\" \"Public Folders\"\r\n")

      assert :noselect in flags
      assert :has_children in flags
    end
  end

  # RFC 9051 Section 7.2.4 - STATUS
  describe "untagged STATUS" do
    test "parses STATUS response" do
      assert {:ok, %Mailbox.Status{name: "INBOX", messages: 17, unseen: 5}} =
               parse("* STATUS \"INBOX\" (MESSAGES 17 UNSEEN 5)\r\n")
    end

    test "parses STATUS with all attributes" do
      assert {:ok, %Mailbox.Status{name: "INBOX", messages: 17, uid_next: 4392, uid_validity: 3857529045}} =
               parse("* STATUS \"INBOX\" (MESSAGES 17 UIDNEXT 4392 UIDVALIDITY 3857529045)\r\n")
    end
  end

  # RFC 9051 Section 7.3.4 - ESEARCH
  describe "untagged ESEARCH" do
    test "parses ESEARCH with MIN MAX COUNT" do
      assert {:ok, %ESearch{tag: "A001", uid: true, min: 1, max: 500, count: 42}} =
               parse("* ESEARCH (TAG \"A001\") UID MIN 1 MAX 500 COUNT 42\r\n")
    end

    test "parses ESEARCH with ALL" do
      assert {:ok, %ESearch{tag: "A001", uid: true, all: "1:3,5"}} =
               parse("* ESEARCH (TAG \"A001\") UID ALL 1:3,5\r\n")
    end

    test "parses ESEARCH without UID" do
      assert {:ok, %ESearch{uid: false, count: 10}} =
               parse("* ESEARCH (TAG \"A001\") COUNT 10\r\n")
    end
  end

  # RFC 9051 Section 7.1 - BYE
  describe "untagged BYE" do
    test "parses BYE response" do
      assert {:ok, {:bye, "server shutting down"}} =
               parse("* BYE server shutting down\r\n")
    end
  end

  # RFC 9051 Section 7.1 - untagged OK
  describe "untagged OK" do
    test "parses OK with response code" do
      assert {:ok, {:ok, {:uid_validity, 3857529045}, "UIDs valid"}} =
               parse("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n")
    end

    test "parses OK without response code" do
      assert {:ok, {:ok, nil, "IMAP4rev2 server ready"}} =
               parse("* OK IMAP4rev2 server ready\r\n")
    end

    test "parses PREAUTH" do
      assert {:ok, {:preauth, nil, "IMAP4rev2 server ready"}} =
               parse("* PREAUTH IMAP4rev2 server ready\r\n")
    end
  end

  # RFC 9051 Section 7.5.1 - EXPUNGE
  describe "untagged EXPUNGE" do
    test "parses EXPUNGE response" do
      assert {:ok, %Message.Expunge{seq: 3}} = parse("* 3 EXPUNGE\r\n")
    end
  end

  # RFC 9051 Section 7.4.2 - FETCH
  describe "untagged FETCH" do
    test "parses FETCH with FLAGS" do
      assert {:ok, %Message.Fetch{seq: 12, attrs: attrs}} =
               parse("* 12 FETCH (FLAGS (\\Seen))\r\n")

      assert attrs.flags == [:seen]
    end

    test "parses FETCH with UID" do
      assert {:ok, %Message.Fetch{seq: 12, attrs: attrs}} =
               parse("* 12 FETCH (UID 4827)\r\n")

      assert attrs.uid == 4827
    end

    test "parses FETCH with FLAGS and UID" do
      assert {:ok, %Message.Fetch{seq: 12, attrs: attrs}} =
               parse("* 12 FETCH (FLAGS (\\Seen) UID 4827)\r\n")

      assert attrs.flags == [:seen]
      assert attrs.uid == 4827
    end

    test "parses FETCH with multiple flags" do
      assert {:ok, %Message.Fetch{seq: 2, attrs: attrs}} =
               parse("* 2 FETCH (FLAGS (\\Deleted \\Seen))\r\n")

      assert :deleted in attrs.flags
      assert :seen in attrs.flags
    end

    test "parses FETCH with INTERNALDATE" do
      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} =
               parse("* 1 FETCH (INTERNALDATE \"17-Jul-1996 02:44:25 -0700\")\r\n")

      assert attrs.internal_date == "17-Jul-1996 02:44:25 -0700"
    end

    test "parses FETCH with RFC822.SIZE" do
      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} =
               parse("* 1 FETCH (RFC822.SIZE 4286)\r\n")

      assert attrs.rfc822_size == 4286
    end

    test "parses FETCH with ENVELOPE" do
      input = "* 1 FETCH (ENVELOPE (\"Mon, 7 Feb 1994 21:52:25 -0800\" \"Test Subject\" ((\"John Doe\" NIL \"john\" \"example.com\")) ((\"John Doe\" NIL \"john\" \"example.com\")) ((\"John Doe\" NIL \"john\" \"example.com\")) ((\"Jane Smith\" NIL \"jane\" \"example.com\")) NIL NIL NIL \"<B27397-0100000@example.com>\"))\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      env = attrs.envelope
      assert %Envelope{} = env
      assert env.date == "Mon, 7 Feb 1994 21:52:25 -0800"
      assert env.subject == "Test Subject"
      assert [%Address{name: "John Doe", mailbox: "john", host: "example.com"}] = env.from
      assert [%Address{name: "Jane Smith", mailbox: "jane", host: "example.com"}] = env.to
      assert env.message_id == "<B27397-0100000@example.com>"
    end

    test "parses FETCH with BODY[] literal" do
      input = "* 1 FETCH (BODY[] {11}\r\nHello World)\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      assert attrs.body[""] == "Hello World"
    end

    test "parses FETCH with BODY[HEADER]" do
      header_data = "Subject: Test\r\nFrom: a\r\n"
      size = byte_size(header_data)
      input = "* 1 FETCH (BODY[HEADER] {#{size}}\r\n#{header_data})\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      assert attrs.body["HEADER"] == header_data
    end

    test "parses FETCH with BODYSTRUCTURE" do
      # Simple text/plain body structure
      input = "* 1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1234 56))\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      bs = attrs.body_structure
      assert %BodyStructure{} = bs
      assert bs.type == "TEXT"
      assert bs.subtype == "PLAIN"
      assert bs.params == %{"CHARSET" => "UTF-8"}
      assert bs.encoding == "7BIT"
      assert bs.size == 1234
      assert bs.lines == 56
    end

    test "parses FETCH with multipart BODYSTRUCTURE" do
      # multipart/alternative with two text parts
      input = "* 1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 5)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 500 20) \"ALTERNATIVE\"))\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      bs = attrs.body_structure
      assert bs.subtype == "ALTERNATIVE"
      assert length(bs.parts) == 2
      [plain, html] = bs.parts
      assert plain.type == "TEXT"
      assert plain.subtype == "PLAIN"
      assert html.type == "TEXT"
      assert html.subtype == "HTML"
    end

    test "parses FETCH with all common attributes" do
      input = "* 1 FETCH (FLAGS (\\Seen) UID 100 RFC822.SIZE 4286 INTERNALDATE \"17-Jul-1996 02:44:25 -0700\")\r\n"

      assert {:ok, %Message.Fetch{seq: 1, attrs: attrs}} = parse(input)
      assert attrs.flags == [:seen]
      assert attrs.uid == 100
      assert attrs.rfc822_size == 4286
      assert attrs.internal_date == "17-Jul-1996 02:44:25 -0700"
    end
  end

  describe "untagged NO and BAD" do
    test "parses untagged NO" do
      assert {:ok, {:no, nil, "Disk quota exceeded"}} =
               parse("* NO Disk quota exceeded\r\n")
    end

    test "parses untagged BAD" do
      assert {:ok, {:bad, nil, "Internal server error"}} =
               parse("* BAD Internal server error\r\n")
    end
  end

  describe "ENABLED response" do
    test "parses ENABLED" do
      assert {:ok, {:enabled, caps}} =
               parse("* ENABLED IMAP4rev2\r\n")

      assert "IMAP4rev2" in caps
    end
  end
end
