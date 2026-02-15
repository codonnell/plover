defmodule Plover.Protocol.CommandBuilderTest do
  use ExUnit.Case, async: true

  alias Plover.Protocol.CommandBuilder
  alias Plover.Command

  # Helper: build and flatten to binary
  defp build(cmd), do: CommandBuilder.build(cmd) |> IO.iodata_to_binary()

  # RFC 9051 Section 6.1 - Client Commands - Any State
  describe "any state commands" do
    test "CAPABILITY" do
      cmd = %Command{tag: "A001", name: "CAPABILITY"}
      assert build(cmd) == "A001 CAPABILITY\r\n"
    end

    test "NOOP" do
      cmd = %Command{tag: "A001", name: "NOOP"}
      assert build(cmd) == "A001 NOOP\r\n"
    end

    test "LOGOUT" do
      cmd = %Command{tag: "A001", name: "LOGOUT"}
      assert build(cmd) == "A001 LOGOUT\r\n"
    end
  end

  # RFC 9051 Section 6.2 - Client Commands - Not Authenticated State
  describe "not authenticated commands" do
    test "LOGIN with simple credentials" do
      cmd = %Command{tag: "A001", name: "LOGIN", args: ["user", "password"]}
      assert build(cmd) == "A001 LOGIN user password\r\n"
    end

    test "LOGIN with quoted password containing spaces" do
      cmd = %Command{tag: "A001", name: "LOGIN", args: ["user", "my password"]}
      assert build(cmd) == "A001 LOGIN user \"my password\"\r\n"
    end

    test "LOGIN with password containing special chars requiring quoting" do
      cmd = %Command{tag: "A001", name: "LOGIN", args: ["user", "pass\"word"]}
      assert build(cmd) == "A001 LOGIN user \"pass\\\"word\"\r\n"
    end

    test "AUTHENTICATE PLAIN" do
      cmd = %Command{tag: "A001", name: "AUTHENTICATE", args: ["PLAIN"]}
      assert build(cmd) == "A001 AUTHENTICATE PLAIN\r\n"
    end

    test "AUTHENTICATE PLAIN with initial response" do
      cmd = %Command{tag: "A001", name: "AUTHENTICATE", args: ["PLAIN", "dXNlcg=="]}
      assert build(cmd) == "A001 AUTHENTICATE PLAIN dXNlcg==\r\n"
    end

    test "AUTHENTICATE XOAUTH2 with initial response" do
      token = "dXNlcj11c2VyQGV4YW1wbGUuY29tAWF1dGg9QmVhcmVyIHRva2VuAQE="
      cmd = %Command{tag: "A001", name: "AUTHENTICATE", args: ["XOAUTH2", token]}
      assert build(cmd) == "A001 AUTHENTICATE XOAUTH2 #{token}\r\n"
    end
  end

  # RFC 9051 Section 6.3 - Client Commands - Authenticated State
  describe "authenticated commands" do
    test "SELECT" do
      cmd = %Command{tag: "A001", name: "SELECT", args: ["INBOX"]}
      assert build(cmd) == "A001 SELECT INBOX\r\n"
    end

    test "SELECT with quoted mailbox name" do
      cmd = %Command{tag: "A001", name: "SELECT", args: ["Sent Items"]}
      assert build(cmd) == "A001 SELECT \"Sent Items\"\r\n"
    end

    test "EXAMINE" do
      cmd = %Command{tag: "A001", name: "EXAMINE", args: ["INBOX"]}
      assert build(cmd) == "A001 EXAMINE INBOX\r\n"
    end

    test "CREATE" do
      cmd = %Command{tag: "A001", name: "CREATE", args: ["NewFolder"]}
      assert build(cmd) == "A001 CREATE NewFolder\r\n"
    end

    test "DELETE" do
      cmd = %Command{tag: "A001", name: "DELETE", args: ["OldFolder"]}
      assert build(cmd) == "A001 DELETE OldFolder\r\n"
    end

    test "LIST" do
      # RFC 9051 Section 6.3.9
      cmd = %Command{tag: "A001", name: "LIST", args: ["", "*"]}
      assert build(cmd) == "A001 LIST \"\" *\r\n"
    end

    test "LIST with reference" do
      cmd = %Command{tag: "A001", name: "LIST", args: ["INBOX/", "%"]}
      assert build(cmd) == "A001 LIST INBOX/ %\r\n"
    end

    test "STATUS" do
      # RFC 9051 Section 6.3.11
      cmd = %Command{tag: "A001", name: "STATUS", args: ["INBOX", {:raw, "(MESSAGES UNSEEN)"}]}
      assert build(cmd) == "A001 STATUS INBOX (MESSAGES UNSEEN)\r\n"
    end

    test "IDLE" do
      cmd = %Command{tag: "A001", name: "IDLE"}
      assert build(cmd) == "A001 IDLE\r\n"
    end

    test "ENABLE" do
      cmd = %Command{tag: "A001", name: "ENABLE", args: ["IMAP4rev2"]}
      assert build(cmd) == "A001 ENABLE IMAP4rev2\r\n"
    end
  end

  # RFC 9051 Section 6.4 - Client Commands - Selected State
  describe "selected state commands" do
    test "CLOSE" do
      cmd = %Command{tag: "A001", name: "CLOSE"}
      assert build(cmd) == "A001 CLOSE\r\n"
    end

    test "UNSELECT" do
      cmd = %Command{tag: "A001", name: "UNSELECT"}
      assert build(cmd) == "A001 UNSELECT\r\n"
    end

    test "EXPUNGE" do
      cmd = %Command{tag: "A001", name: "EXPUNGE"}
      assert build(cmd) == "A001 EXPUNGE\r\n"
    end

    test "SEARCH" do
      # RFC 9051 Section 6.4.4
      cmd = %Command{tag: "A001", name: "SEARCH", args: ["UNSEEN"]}
      assert build(cmd) == "A001 SEARCH UNSEEN\r\n"
    end

    test "SEARCH with multiple criteria" do
      cmd = %Command{tag: "A001", name: "SEARCH", args: ["UNSEEN", "FROM", "john@example.com"]}
      assert build(cmd) == "A001 SEARCH UNSEEN FROM john@example.com\r\n"
    end

    test "FETCH" do
      # RFC 9051 Section 6.4.5
      cmd = %Command{tag: "A001", name: "FETCH", args: ["1:5", {:raw, "(FLAGS UID ENVELOPE)"}]}
      assert build(cmd) == "A001 FETCH 1:5 (FLAGS UID ENVELOPE)\r\n"
    end

    test "FETCH single item" do
      cmd = %Command{tag: "A001", name: "FETCH", args: ["1", "FLAGS"]}
      assert build(cmd) == "A001 FETCH 1 FLAGS\r\n"
    end

    test "FETCH with BODY.PEEK" do
      cmd = %Command{tag: "A001", name: "FETCH", args: ["1", "BODY.PEEK[HEADER]"]}
      assert build(cmd) == "A001 FETCH 1 BODY.PEEK[HEADER]\r\n"
    end

    test "STORE" do
      # RFC 9051 Section 6.4.6
      cmd = %Command{tag: "A001", name: "STORE", args: ["2:4", "+FLAGS", {:raw, "(\\Deleted)"}]}
      assert build(cmd) == "A001 STORE 2:4 +FLAGS (\\Deleted)\r\n"
    end

    test "STORE FLAGS.SILENT" do
      cmd = %Command{tag: "A001", name: "STORE", args: ["1", "FLAGS.SILENT", {:raw, "(\\Seen)"}]}
      assert build(cmd) == "A001 STORE 1 FLAGS.SILENT (\\Seen)\r\n"
    end

    test "COPY" do
      # RFC 9051 Section 6.4.7
      cmd = %Command{tag: "A001", name: "COPY", args: ["2:4", "MEETING"]}
      assert build(cmd) == "A001 COPY 2:4 MEETING\r\n"
    end

    test "MOVE" do
      # RFC 9051 Section 6.4.8
      cmd = %Command{tag: "A001", name: "MOVE", args: ["1:3", "Trash"]}
      assert build(cmd) == "A001 MOVE 1:3 Trash\r\n"
    end
  end

  # UID prefix commands
  describe "UID commands" do
    test "UID FETCH" do
      cmd = %Command{
        tag: "A001",
        name: "UID FETCH",
        args: ["100:200", {:raw, "(FLAGS ENVELOPE)"}]
      }

      assert build(cmd) == "A001 UID FETCH 100:200 (FLAGS ENVELOPE)\r\n"
    end

    test "UID STORE" do
      cmd = %Command{
        tag: "A001",
        name: "UID STORE",
        args: ["100", "+FLAGS.SILENT", {:raw, "(\\Seen)"}]
      }

      assert build(cmd) == "A001 UID STORE 100 +FLAGS.SILENT (\\Seen)\r\n"
    end

    test "UID COPY" do
      cmd = %Command{tag: "A001", name: "UID COPY", args: ["100:200", "Archive"]}
      assert build(cmd) == "A001 UID COPY 100:200 Archive\r\n"
    end

    test "UID MOVE" do
      cmd = %Command{tag: "A001", name: "UID MOVE", args: ["100:200", "Trash"]}
      assert build(cmd) == "A001 UID MOVE 100:200 Trash\r\n"
    end

    test "UID SEARCH" do
      cmd = %Command{tag: "A001", name: "UID SEARCH", args: ["ALL"]}
      assert build(cmd) == "A001 UID SEARCH ALL\r\n"
    end

    test "UID EXPUNGE" do
      # RFC 9051 Section 6.4.9
      cmd = %Command{tag: "A001", name: "UID EXPUNGE", args: ["100:200"]}
      assert build(cmd) == "A001 UID EXPUNGE 100:200\r\n"
    end
  end

  # APPEND requires literal handling
  describe "APPEND command" do
    test "APPEND with literal" do
      message = "From: user@example.com\r\nSubject: Test\r\n\r\nBody"

      cmd = %Command{
        tag: "A001",
        name: "APPEND",
        args: ["INBOX", {:raw, "(\\Seen)"}, {:literal, message}]
      }

      assert {:literal, first_part, literal_data} = CommandBuilder.build(cmd)

      assert IO.iodata_to_binary(first_part) ==
               "A001 APPEND INBOX (\\Seen) {#{byte_size(message)}}\r\n"

      assert literal_data == message
    end

    test "APPEND with flags and date" do
      message = "test"

      cmd = %Command{
        tag: "A001",
        name: "APPEND",
        args: [
          "INBOX",
          {:raw, "(\\Seen \\Draft)"},
          "25-Jan-2024 10:00:00 +0000",
          {:literal, message}
        ]
      }

      assert {:literal, first_part, literal_data} = CommandBuilder.build(cmd)

      assert IO.iodata_to_binary(first_part) ==
               "A001 APPEND INBOX (\\Seen \\Draft) \"25-Jan-2024 10:00:00 +0000\" {4}\r\n"

      assert literal_data == message
    end
  end

  # Quoting rules
  describe "astring quoting" do
    test "simple atom does not need quoting" do
      cmd = %Command{tag: "A001", name: "SELECT", args: ["INBOX"]}
      assert build(cmd) == "A001 SELECT INBOX\r\n"
    end

    test "string with spaces is quoted" do
      cmd = %Command{tag: "A001", name: "SELECT", args: ["Sent Items"]}
      assert build(cmd) == "A001 SELECT \"Sent Items\"\r\n"
    end

    test "string with parentheses is quoted" do
      cmd = %Command{tag: "A001", name: "SELECT", args: ["folder(1)"]}
      assert build(cmd) == "A001 SELECT \"folder(1)\"\r\n"
    end

    test "empty string is quoted" do
      cmd = %Command{tag: "A001", name: "LIST", args: ["", "*"]}
      assert build(cmd) == "A001 LIST \"\" *\r\n"
    end
  end

  # DONE command (for IDLE)
  describe "DONE" do
    test "builds DONE" do
      assert CommandBuilder.build_done() |> IO.iodata_to_binary() == "DONE\r\n"
    end
  end
end
