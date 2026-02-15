defmodule Plover.Protocol.ResponseEncoderTest do
  use ExUnit.Case, async: true

  alias Plover.Protocol.{ResponseEncoder, Tokenizer, Parser}
  alias Plover.Response.{Tagged, Continuation, BodyStructure, Envelope, Address, ESearch}
  alias Plover.Response.Mailbox
  alias Plover.Response.Message

  # Helper: encode → tokenize → parse → compare
  defp round_trip(struct) do
    wire = ResponseEncoder.encode(struct)
    assert is_binary(wire), "encode should return binary, got: #{inspect(wire)}"
    assert String.ends_with?(wire, "\r\n"), "wire format should end with CRLF"
    {:ok, tokens, _rest} = Tokenizer.tokenize(wire)
    {:ok, parsed} = Parser.parse(tokens)
    parsed
  end

  # --- Tagged responses ---

  describe "Tagged responses" do
    test "OK with text" do
      struct = %Tagged{tag: "A0001", status: :ok, text: "done"}
      parsed = round_trip(struct)
      assert %Tagged{tag: "A0001", status: :ok, text: "done"} = parsed
    end

    test "NO with text" do
      struct = %Tagged{tag: "A0002", status: :no, text: "access denied"}
      parsed = round_trip(struct)
      assert %Tagged{tag: "A0002", status: :no, text: "access denied"} = parsed
    end

    test "BAD with text" do
      struct = %Tagged{tag: "A0003", status: :bad, text: "invalid command"}
      parsed = round_trip(struct)
      assert %Tagged{tag: "A0003", status: :bad, text: "invalid command"} = parsed
    end

    test "OK with CAPABILITY response code" do
      struct = %Tagged{
        tag: "A0001",
        status: :ok,
        code: {:capability, ["IMAP4rev2", "IDLE"]},
        text: "LOGIN completed"
      }

      parsed = round_trip(struct)
      assert %Tagged{status: :ok, code: {:capability, caps}, text: "LOGIN completed"} = parsed
      assert "IMAP4rev2" in caps
      assert "IDLE" in caps
    end

    test "OK with READ-WRITE response code" do
      struct = %Tagged{
        tag: "A0002",
        status: :ok,
        code: {:read_write, nil},
        text: "SELECT completed"
      }

      parsed = round_trip(struct)
      assert %Tagged{code: {:read_write, nil}} = parsed
    end

    test "OK with READ-ONLY response code" do
      struct = %Tagged{tag: "A0001", status: :ok, code: {:read_only, nil}, text: "done"}
      parsed = round_trip(struct)
      assert %Tagged{code: {:read_only, nil}} = parsed
    end

    test "OK with UIDVALIDITY response code" do
      struct = %Tagged{
        tag: "A0001",
        status: :ok,
        code: {:uid_validity, 3_857_529_045},
        text: "UIDs valid"
      }

      parsed = round_trip(struct)
      assert %Tagged{code: {:uid_validity, 3_857_529_045}} = parsed
    end

    test "OK with UIDNEXT response code" do
      struct = %Tagged{
        tag: "A0001",
        status: :ok,
        code: {:uid_next, 4392},
        text: "predicted next UID"
      }

      parsed = round_trip(struct)
      assert %Tagged{code: {:uid_next, 4392}} = parsed
    end

    test "OK with APPENDUID response code" do
      struct = %Tagged{
        tag: "A0001",
        status: :ok,
        code: {:append_uid, {38505, 3955}},
        text: "APPEND completed"
      }

      parsed = round_trip(struct)
      assert %Tagged{code: {:append_uid, {38505, 3955}}} = parsed
    end

    test "OK with PERMANENT_FLAGS response code" do
      struct = %Tagged{
        tag: "A0001",
        status: :ok,
        code: {:permanent_flags, [:seen, :answered, :wildcard]},
        text: "Flags permitted"
      }

      parsed = round_trip(struct)
      assert %Tagged{code: {:permanent_flags, flags}} = parsed
      assert :seen in flags
      assert :answered in flags
      assert :wildcard in flags
    end

    test "all nil-value response codes" do
      codes = [
        {:alert, nil, "ALERT"},
        {:parse, nil, "PARSE"},
        {:read_only, nil, "READ-ONLY"},
        {:read_write, nil, "READ-WRITE"},
        {:try_create, nil, "TRYCREATE"},
        {:uid_not_sticky, nil, "UIDNOTSTICKY"},
        {:closed, nil, "CLOSED"},
        {:authentication_failed, nil, "AUTHENTICATIONFAILED"},
        {:authorization_failed, nil, "AUTHORIZATIONFAILED"},
        {:expired, nil, "EXPIRED"},
        {:privacy_required, nil, "PRIVACYREQUIRED"},
        {:contact_admin, nil, "CONTACTADMIN"},
        {:no_perm, nil, "NOPERM"},
        {:in_use, nil, "INUSE"},
        {:expunge_issued, nil, "EXPUNGEISSUED"},
        {:over_quota, nil, "OVERQUOTA"},
        {:already_exists, nil, "ALREADYEXISTS"},
        {:nonexistent, nil, "NONEXISTENT"},
        {:unavailable, nil, "UNAVAILABLE"},
        {:server_bug, nil, "SERVERBUG"},
        {:client_bug, nil, "CLIENTBUG"},
        {:cannot, nil, "CANNOT"},
        {:limit, nil, "LIMIT"},
        {:corruption, nil, "CORRUPTION"},
        {:has_children, nil, "HASCHILDREN"},
        {:not_saved, nil, "NOTSAVED"},
        {:unknown_cte, nil, "UNKNOWN-CTE"}
      ]

      for {code_atom, nil, _wire_name} <- codes do
        struct = %Tagged{tag: "A0001", status: :ok, code: {code_atom, nil}, text: "test"}
        parsed = round_trip(struct)
        assert %Tagged{code: {^code_atom, nil}} = parsed
      end
    end

    test "no response code" do
      struct = %Tagged{tag: "A0001", status: :ok, code: nil, text: "done"}
      parsed = round_trip(struct)
      assert %Tagged{code: nil, text: "done"} = parsed
    end
  end

  # --- Untagged responses ---

  describe "Mailbox.Exists" do
    test "encodes exists count" do
      struct = %Mailbox.Exists{count: 172}
      parsed = round_trip(struct)
      assert %Mailbox.Exists{count: 172} = parsed
    end
  end

  describe "Mailbox.Flags" do
    test "encodes standard flags" do
      struct = %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
      parsed = round_trip(struct)
      assert %Mailbox.Flags{flags: flags} = parsed
      assert :answered in flags
      assert :seen in flags
      assert :draft in flags
    end

    test "encodes empty flags" do
      struct = %Mailbox.Flags{flags: []}
      parsed = round_trip(struct)
      assert %Mailbox.Flags{flags: []} = parsed
    end
  end

  describe "Mailbox.List" do
    test "encodes list with flags and delimiter" do
      struct = %Mailbox.List{flags: [:noselect], delimiter: "/", name: "Drafts"}
      parsed = round_trip(struct)
      assert %Mailbox.List{flags: [:noselect], delimiter: "/", name: "Drafts"} = parsed
    end

    test "encodes list with nil delimiter" do
      struct = %Mailbox.List{flags: [], delimiter: nil, name: "INBOX"}
      parsed = round_trip(struct)
      assert %Mailbox.List{delimiter: nil, name: "INBOX"} = parsed
    end

    test "encodes list with multiple flags" do
      struct = %Mailbox.List{
        flags: [:has_children, :noselect],
        delimiter: ".",
        name: "Archive"
      }

      parsed = round_trip(struct)
      assert %Mailbox.List{flags: flags} = parsed
      assert :has_children in flags
      assert :noselect in flags
    end

    test "encodes list with quoted mailbox name containing space" do
      struct = %Mailbox.List{flags: [], delimiter: "/", name: "Sent Items"}
      parsed = round_trip(struct)
      assert %Mailbox.List{name: "Sent Items"} = parsed
    end
  end

  describe "Mailbox.Status" do
    test "encodes status with all attributes" do
      struct = %Mailbox.Status{
        name: "INBOX",
        messages: 10,
        unseen: 3,
        uid_next: 200,
        uid_validity: 12345
      }

      parsed = round_trip(struct)
      assert %Mailbox.Status{name: "INBOX", messages: 10, unseen: 3} = parsed
    end

    test "encodes status with subset of attributes" do
      struct = %Mailbox.Status{name: "INBOX", messages: 5}
      parsed = round_trip(struct)
      assert %Mailbox.Status{name: "INBOX", messages: 5} = parsed
    end
  end

  describe "Message.Expunge" do
    test "encodes expunge" do
      struct = %Message.Expunge{seq: 5}
      parsed = round_trip(struct)
      assert %Message.Expunge{seq: 5} = parsed
    end
  end

  describe "Message.Fetch" do
    test "encodes flags and uid" do
      struct = %Message.Fetch{seq: 1, attrs: %{flags: [:seen], uid: 100}}
      parsed = round_trip(struct)
      assert %Message.Fetch{seq: 1, attrs: attrs} = parsed
      assert attrs.uid == 100
      assert :seen in attrs.flags
    end

    test "encodes multiple flags" do
      struct = %Message.Fetch{
        seq: 2,
        attrs: %{flags: [:seen, :flagged, :answered], uid: 101}
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: attrs} = parsed
      assert :seen in attrs.flags
      assert :flagged in attrs.flags
      assert :answered in attrs.flags
    end

    test "encodes internal date" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{internal_date: "17-Jul-1996 02:44:25 -0700"}
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{internal_date: "17-Jul-1996 02:44:25 -0700"}} = parsed
    end

    test "encodes rfc822 size" do
      struct = %Message.Fetch{seq: 1, attrs: %{rfc822_size: 4286}}
      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{rfc822_size: 4286}} = parsed
    end

    test "encodes body section with literal data" do
      body_data = "Hello, World!\r\nThis is a test."

      struct = %Message.Fetch{
        seq: 1,
        attrs: %{body: %{"" => body_data}}
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{body: %{"" => ^body_data}}} = parsed
    end

    test "encodes body section with numbered section" do
      body_data = "<html>test</html>"

      struct = %Message.Fetch{
        seq: 1,
        attrs: %{body: %{"1.2" => body_data}}
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{body: %{"1.2" => ^body_data}}} = parsed
    end

    test "encodes envelope" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          envelope: %Envelope{
            date: "Mon, 7 Feb 1994 21:52:25 -0800",
            subject: "Test Subject",
            from: [%Address{name: "John", adl: nil, mailbox: "john", host: "example.com"}],
            sender: [%Address{name: "John", adl: nil, mailbox: "john", host: "example.com"}],
            reply_to: [%Address{name: "John", adl: nil, mailbox: "john", host: "example.com"}],
            to: [%Address{name: "Jane", adl: nil, mailbox: "jane", host: "example.com"}],
            cc: [],
            bcc: [],
            in_reply_to: nil,
            message_id: "<abc@example.com>"
          }
        }
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{envelope: env}} = parsed
      assert env.subject == "Test Subject"
      assert env.message_id == "<abc@example.com>"
      assert [%Address{mailbox: "john"}] = env.from
      assert [%Address{mailbox: "jane"}] = env.to
    end

    test "encodes envelope with nil address lists" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          envelope: %Envelope{
            date: "Mon, 7 Feb 1994 21:52:25 -0800",
            subject: nil,
            from: [],
            sender: [],
            reply_to: [],
            to: [],
            cc: [],
            bcc: [],
            in_reply_to: nil,
            message_id: nil
          }
        }
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{envelope: env}} = parsed
      assert env.subject == nil
      assert env.message_id == nil
    end

    test "encodes simple body structure" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          body_structure: %BodyStructure{
            type: "TEXT",
            subtype: "PLAIN",
            params: %{"CHARSET" => "UTF-8"},
            id: nil,
            description: nil,
            encoding: "7BIT",
            size: 1234,
            lines: 56
          }
        }
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{body_structure: bs}} = parsed
      assert bs.type == "TEXT"
      assert bs.subtype == "PLAIN"
      assert bs.encoding == "7BIT"
      assert bs.size == 1234
      assert bs.lines == 56
      assert bs.params == %{"CHARSET" => "UTF-8"}
    end

    test "encodes multipart body structure" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          body_structure: %BodyStructure{
            type: "multipart",
            subtype: "MIXED",
            parts: [
              %BodyStructure{
                type: "TEXT",
                subtype: "PLAIN",
                params: %{"CHARSET" => "US-ASCII"},
                id: nil,
                description: nil,
                encoding: "7BIT",
                size: 100,
                lines: 5
              },
              %BodyStructure{
                type: "APPLICATION",
                subtype: "PDF",
                params: %{"NAME" => "report.pdf"},
                id: nil,
                description: nil,
                encoding: "BASE64",
                size: 45678
              }
            ]
          }
        }
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{body_structure: bs}} = parsed
      assert bs.type == "multipart"
      assert bs.subtype == "MIXED"
      assert length(bs.parts) == 2
      [text_part, pdf_part] = bs.parts
      assert text_part.type == "TEXT"
      assert text_part.subtype == "PLAIN"
      assert text_part.lines == 5
      assert pdf_part.type == "APPLICATION"
      assert pdf_part.subtype == "PDF"
    end

    test "encodes nested multipart body structure" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          body_structure: %BodyStructure{
            type: "multipart",
            subtype: "MIXED",
            parts: [
              %BodyStructure{
                type: "multipart",
                subtype: "ALTERNATIVE",
                parts: [
                  %BodyStructure{
                    type: "TEXT",
                    subtype: "PLAIN",
                    params: %{},
                    encoding: "7BIT",
                    size: 50,
                    lines: 2
                  },
                  %BodyStructure{
                    type: "TEXT",
                    subtype: "HTML",
                    params: %{},
                    encoding: "QUOTED-PRINTABLE",
                    size: 200,
                    lines: 10
                  }
                ]
              },
              %BodyStructure{
                type: "IMAGE",
                subtype: "PNG",
                params: %{},
                encoding: "BASE64",
                size: 98765
              }
            ]
          }
        }
      }

      parsed = round_trip(struct)
      assert %Message.Fetch{attrs: %{body_structure: bs}} = parsed
      assert bs.type == "multipart"
      assert length(bs.parts) == 2
      [alternative, image] = bs.parts
      assert alternative.type == "multipart"
      assert alternative.subtype == "ALTERNATIVE"
      assert length(alternative.parts) == 2
      assert image.type == "IMAGE"
    end

    test "encodes uid only" do
      struct = %Message.Fetch{seq: 3, attrs: %{uid: 500}}
      parsed = round_trip(struct)
      assert %Message.Fetch{seq: 3, attrs: %{uid: 500}} = parsed
    end

    test "encodes all attrs together" do
      struct = %Message.Fetch{
        seq: 1,
        attrs: %{
          flags: [:seen, :answered],
          uid: 100,
          rfc822_size: 5000,
          internal_date: "01-Jan-2024 12:00:00 +0000"
        }
      }

      parsed = round_trip(struct)
      attrs = parsed.attrs
      assert attrs.uid == 100
      assert attrs.rfc822_size == 5000
      assert attrs.internal_date == "01-Jan-2024 12:00:00 +0000"
      assert :seen in attrs.flags
    end
  end

  describe "ESearch" do
    test "encodes esearch with UID and COUNT" do
      struct = %ESearch{uid: true, count: 5}
      parsed = round_trip(struct)
      assert %ESearch{uid: true, count: 5} = parsed
    end

    test "encodes esearch with ALL" do
      struct = %ESearch{uid: true, all: "1:5"}
      parsed = round_trip(struct)
      assert %ESearch{uid: true, all: "1:5"} = parsed
    end

    test "encodes esearch with MIN and MAX" do
      struct = %ESearch{uid: false, min: 1, max: 100}
      parsed = round_trip(struct)
      assert %ESearch{uid: false, min: 1, max: 100} = parsed
    end

    test "encodes esearch with tag correlator" do
      struct = %ESearch{tag: "A0005", uid: true, count: 10, all: "1:10"}
      parsed = round_trip(struct)
      assert %ESearch{tag: "A0005", uid: true, count: 10, all: "1:10"} = parsed
    end

    test "encodes esearch with no results" do
      struct = %ESearch{uid: true}
      parsed = round_trip(struct)
      assert %ESearch{uid: true} = parsed
    end
  end

  describe "Continuation" do
    test "encodes continuation with text" do
      struct = %Continuation{text: "Ready for literal data"}
      parsed = round_trip(struct)
      assert %Continuation{text: "Ready for literal data"} = parsed
    end

    test "encodes continuation with empty text" do
      struct = %Continuation{text: ""}
      parsed = round_trip(struct)
      assert %Continuation{text: ""} = parsed
    end
  end

  # --- Untagged OK/NO/BAD/BYE ---

  describe "encode_untagged/2" do
    test "encodes untagged OK" do
      wire = ResponseEncoder.encode_untagged(:ok, text: "Server ready")
      assert wire == "* OK Server ready\r\n"
    end

    test "encodes untagged OK with capability" do
      wire =
        ResponseEncoder.encode_untagged(:ok,
          code: {:capability, ["IMAP4rev2"]},
          text: "Server ready"
        )

      assert wire == "* OK [CAPABILITY IMAP4rev2] Server ready\r\n"
    end

    test "encodes untagged BYE" do
      wire = ResponseEncoder.encode_untagged(:bye, text: "server logging out")
      assert wire == "* BYE server logging out\r\n"
    end

    test "encodes untagged NO" do
      wire = ResponseEncoder.encode_untagged(:no, text: "access denied")
      assert wire == "* NO access denied\r\n"
    end

    test "encodes untagged BAD" do
      wire = ResponseEncoder.encode_untagged(:bad, text: "invalid command")
      assert wire == "* BAD invalid command\r\n"
    end
  end

  # --- Direct wire output tests ---

  describe "wire format correctness" do
    test "Exists output format" do
      assert ResponseEncoder.encode(%Mailbox.Exists{count: 100}) == "* 100 EXISTS\r\n"
    end

    test "Expunge output format" do
      assert ResponseEncoder.encode(%Message.Expunge{seq: 5}) == "* 5 EXPUNGE\r\n"
    end

    test "Flags output format" do
      wire = ResponseEncoder.encode(%Mailbox.Flags{flags: [:seen, :flagged]})
      assert wire =~ ~r/\* FLAGS \(.*\)\r\n/
    end
  end
end
