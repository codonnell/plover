defmodule Plover.Protocol.TokenizerTest do
  use ExUnit.Case, async: true

  alias Plover.Protocol.Tokenizer

  # RFC 9051 Section 9 - atom = 1*ATOM-CHAR
  # ATOM-CHAR = <any CHAR except atom-specials>
  # atom-specials = "(" / ")" / "{" / SP / CTL / list-wildcards / quoted-specials / resp-specials
  describe "atoms" do
    test "simple atom" do
      assert Tokenizer.tokenize("INBOX\r\n") == {:ok, [{:atom, "INBOX"}, :crlf], ""}
    end

    test "atom with mixed case" do
      assert Tokenizer.tokenize("InBoX\r\n") == {:ok, [{:atom, "InBoX"}, :crlf], ""}
    end

    test "atom with digits" do
      assert Tokenizer.tokenize("A001\r\n") == {:ok, [{:atom, "A001"}, :crlf], ""}
    end

    test "atom with allowed special chars" do
      # RFC 9051: ATOM-CHAR excludes ( ) { SP CTL % * " \ ]
      # But allows other printable chars like -, _, /, :, etc.
      assert {:ok, [{:atom, "HEADER.FIELDS"} | _], _} =
               Tokenizer.tokenize("HEADER.FIELDS\r\n")
    end

    test "NIL atom" do
      assert Tokenizer.tokenize("NIL\r\n") == {:ok, [:nil, :crlf], ""}
    end
  end

  # RFC 9051 Section 9 - number = 1*DIGIT
  describe "numbers" do
    test "simple number" do
      assert Tokenizer.tokenize("42\r\n") == {:ok, [{:number, 42}, :crlf], ""}
    end

    test "zero" do
      assert Tokenizer.tokenize("0\r\n") == {:ok, [{:number, 0}, :crlf], ""}
    end

    test "large number" do
      assert Tokenizer.tokenize("4294967295\r\n") ==
               {:ok, [{:number, 4_294_967_295}, :crlf], ""}
    end
  end

  # RFC 9051 Section 9 - quoted = DQUOTE *QUOTED-CHAR DQUOTE
  # QUOTED-CHAR = <any TEXT-CHAR except quoted-specials> / "\" quoted-specials
  # quoted-specials = DQUOTE / "\"
  describe "quoted strings" do
    test "simple quoted string" do
      assert Tokenizer.tokenize("\"hello\"\r\n") ==
               {:ok, [{:quoted_string, "hello"}, :crlf], ""}
    end

    test "empty quoted string" do
      assert Tokenizer.tokenize("\"\"\r\n") ==
               {:ok, [{:quoted_string, ""}, :crlf], ""}
    end

    test "quoted string with escaped quote" do
      # RFC 9051: QUOTED-CHAR includes "\" quoted-specials
      assert Tokenizer.tokenize("\"hello\\\"world\"\r\n") ==
               {:ok, [{:quoted_string, "hello\"world"}, :crlf], ""}
    end

    test "quoted string with escaped backslash" do
      assert Tokenizer.tokenize("\"hello\\\\world\"\r\n") ==
               {:ok, [{:quoted_string, "hello\\world"}, :crlf], ""}
    end

    test "quoted string with spaces" do
      assert Tokenizer.tokenize("\"hello world\"\r\n") ==
               {:ok, [{:quoted_string, "hello world"}, :crlf], ""}
    end
  end

  # RFC 9051 Section 9 - literal = "{" number64 ["+"] "}" CRLF *CHAR8
  describe "literals" do
    test "synchronizing literal" do
      assert Tokenizer.tokenize("{5}\r\nhello\r\n") ==
               {:ok, [{:literal, "hello"}, :crlf], ""}
    end

    test "non-synchronizing literal" do
      assert Tokenizer.tokenize("{5+}\r\nhello\r\n") ==
               {:ok, [{:literal, "hello"}, :crlf], ""}
    end

    test "zero-length literal" do
      assert Tokenizer.tokenize("{0}\r\n\r\n") ==
               {:ok, [{:literal, ""}, :crlf], ""}
    end

    test "literal with binary data" do
      # Literal can contain any CHAR8 (including CRLF within the counted bytes)
      # First verify a simple literal works (from earlier test)
      assert {:ok, [{:literal, "hello"}, :crlf], ""} = Tokenizer.tokenize("{5}\r\nhello\r\n")

      # Now test literal containing CRLF within counted bytes
      # {7}\r\n means 7 bytes follow: "hi\r\nby" = h,i,\r,\n,b,y = 6 bytes...
      # Wait: h(1) i(2) \r(3) \n(4) b(5) y(6) = 6 bytes, not 7!
      # Let's use the right count
      input = "{6}\r\nhi\r\nby\r\n"
      result = Tokenizer.tokenize(input)
      assert result == {:ok, [{:literal, "hi\r\nby"}, :crlf], ""}
    end

    test "incomplete literal returns error" do
      assert {:error, _} = Tokenizer.tokenize("{10}\r\nhello")
    end
  end

  # RFC 9051 Section 9 - flag = "\" atom / "\*"
  describe "flags" do
    test "system flag \\Seen" do
      assert Tokenizer.tokenize("\\Seen\r\n") == {:ok, [{:flag, "\\Seen"}, :crlf], ""}
    end

    test "system flag \\Answered" do
      assert Tokenizer.tokenize("\\Answered\r\n") ==
               {:ok, [{:flag, "\\Answered"}, :crlf], ""}
    end

    test "system flag \\Flagged" do
      assert Tokenizer.tokenize("\\Flagged\r\n") ==
               {:ok, [{:flag, "\\Flagged"}, :crlf], ""}
    end

    test "system flag \\Deleted" do
      assert Tokenizer.tokenize("\\Deleted\r\n") ==
               {:ok, [{:flag, "\\Deleted"}, :crlf], ""}
    end

    test "system flag \\Draft" do
      assert Tokenizer.tokenize("\\Draft\r\n") ==
               {:ok, [{:flag, "\\Draft"}, :crlf], ""}
    end

    test "permanent flag wildcard \\*" do
      # RFC 9051: flag-perm = flag / "\*"
      assert Tokenizer.tokenize("\\*\r\n") == {:ok, [{:flag, "\\*"}, :crlf], ""}
    end

    test "flag extension" do
      assert Tokenizer.tokenize("\\Junk\r\n") == {:ok, [{:flag, "\\Junk"}, :crlf], ""}
    end

    test "obsolete \\Recent flag" do
      assert Tokenizer.tokenize("\\Recent\r\n") ==
               {:ok, [{:flag, "\\Recent"}, :crlf], ""}
    end
  end

  # Structural tokens
  describe "structural tokens" do
    test "parentheses" do
      assert Tokenizer.tokenize("()\r\n") == {:ok, [:lparen, :rparen, :crlf], ""}
    end

    test "brackets" do
      assert Tokenizer.tokenize("[]\r\n") == {:ok, [:lbracket, :rbracket, :crlf], ""}
    end

    test "star (untagged response prefix)" do
      # RFC 9051: response-data = "*" SP ...
      assert Tokenizer.tokenize("*\r\n") == {:ok, [:star, :crlf], ""}
    end

    test "plus (continuation request)" do
      # RFC 9051: continue-req = "+" SP (resp-text / base64) CRLF
      assert Tokenizer.tokenize("+\r\n") == {:ok, [:plus, :crlf], ""}
    end

    test "CRLF" do
      assert Tokenizer.tokenize("\r\n") == {:ok, [:crlf], ""}
    end
  end

  # Complex response lines from real IMAP sessions
  describe "complete response lines" do
    test "untagged OK greeting" do
      # RFC 9051 Section 7 example
      input = "* OK IMAP4rev2 server ready\r\n"

      assert {:ok, [:star, {:atom, "OK"}, {:atom, "IMAP4rev2"}, {:atom, "server"}, {:atom, "ready"}, :crlf], ""} =
               Tokenizer.tokenize(input)
    end

    test "tagged OK response" do
      input = "A001 OK SELECT completed\r\n"

      assert {:ok, [{:atom, "A001"}, {:atom, "OK"}, {:atom, "SELECT"}, {:atom, "completed"}, :crlf], ""} =
               Tokenizer.tokenize(input)
    end

    test "capability response" do
      input = "* CAPABILITY IMAP4rev2 AUTH=PLAIN\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "CAPABILITY"},
                {:atom, "IMAP4rev2"},
                {:atom, "AUTH=PLAIN"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "flags response" do
      # RFC 9051 Section 7.2.6
      input = "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "FLAGS"},
                :lparen,
                {:flag, "\\Answered"},
                {:flag, "\\Flagged"},
                {:flag, "\\Deleted"},
                {:flag, "\\Seen"},
                {:flag, "\\Draft"},
                :rparen,
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "EXISTS response" do
      # RFC 9051 Section 7.3.1
      input = "* 172 EXISTS\r\n"

      assert {:ok, [:star, {:number, 172}, {:atom, "EXISTS"}, :crlf], ""} =
               Tokenizer.tokenize(input)
    end

    test "LIST response" do
      # RFC 9051 Section 7.2.2
      input = "* LIST (\\HasNoChildren) \"/\" \"INBOX/Sent\"\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "LIST"},
                :lparen,
                {:flag, "\\HasNoChildren"},
                :rparen,
                {:quoted_string, "/"},
                {:quoted_string, "INBOX/Sent"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "FETCH response with FLAGS and UID" do
      input = "* 12 FETCH (FLAGS (\\Seen) UID 4827)\r\n"

      assert {:ok,
              [
                :star,
                {:number, 12},
                {:atom, "FETCH"},
                :lparen,
                {:atom, "FLAGS"},
                :lparen,
                {:flag, "\\Seen"},
                :rparen,
                {:atom, "UID"},
                {:number, 4827},
                :rparen,
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "OK response with response code" do
      # RFC 9051 Section 7.1
      input = "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "OK"},
                :lbracket,
                {:atom, "UIDVALIDITY"},
                {:number, 3_857_529_045},
                :rbracket,
                {:atom, "UIDs"},
                {:atom, "valid"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "continuation request" do
      input = "+ ready for literal data\r\n"

      assert {:ok,
              [
                :plus,
                {:atom, "ready"},
                {:atom, "for"},
                {:atom, "literal"},
                {:atom, "data"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "response with literal in body" do
      input = "* 1 FETCH (BODY[] {11}\r\nHello World)\r\n"

      assert {:ok,
              [
                :star,
                {:number, 1},
                {:atom, "FETCH"},
                :lparen,
                {:atom, "BODY"},
                :lbracket,
                :rbracket,
                {:literal, "Hello World"},
                :rparen,
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "STATUS response" do
      # RFC 9051 Section 7.2.4
      input = "* STATUS \"INBOX\" (MESSAGES 17 UNSEEN 5)\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "STATUS"},
                {:quoted_string, "INBOX"},
                :lparen,
                {:atom, "MESSAGES"},
                {:number, 17},
                {:atom, "UNSEEN"},
                {:number, 5},
                :rparen,
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "ESEARCH response" do
      # RFC 9051 Section 7.3.4
      input = "* ESEARCH (TAG \"A001\") UID MIN 1 MAX 500 COUNT 42\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "ESEARCH"},
                :lparen,
                {:atom, "TAG"},
                {:quoted_string, "A001"},
                :rparen,
                {:atom, "UID"},
                {:atom, "MIN"},
                {:number, 1},
                {:atom, "MAX"},
                {:number, 500},
                {:atom, "COUNT"},
                {:number, 42},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "BYE response" do
      input = "* BYE server shutting down\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "BYE"},
                {:atom, "server"},
                {:atom, "shutting"},
                {:atom, "down"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "tagged NO response" do
      input = "A001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"

      assert {:ok,
              [
                {:atom, "A001"},
                {:atom, "NO"},
                :lbracket,
                {:atom, "AUTHENTICATIONFAILED"},
                :rbracket,
                {:atom, "Invalid"},
                {:atom, "credentials"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "tagged BAD response" do
      input = "A001 BAD command unknown\r\n"

      assert {:ok,
              [
                {:atom, "A001"},
                {:atom, "BAD"},
                {:atom, "command"},
                {:atom, "unknown"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end
  end

  describe "incomplete input" do
    test "returns error for incomplete line (no CRLF)" do
      assert {:error, _} = Tokenizer.tokenize("* OK hello")
    end

    test "returns remaining data after first line" do
      input = "* OK hello\r\n* BYE\r\n"

      assert {:ok, [:star, {:atom, "OK"}, {:atom, "hello"}, :crlf], "* BYE\r\n"} =
               Tokenizer.tokenize(input)
    end
  end

  describe "FETCH with envelope" do
    test "tokenizes envelope components" do
      # Simplified envelope - verifying parenthesized structure tokenizes
      input = "* 1 FETCH (ENVELOPE (\"Mon, 7 Feb 1994 21:52:25 -0800\" \"Test\" ((\"John\" NIL \"john\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"

      assert {:ok, tokens, ""} = Tokenizer.tokenize(input)
      assert :star == hd(tokens)
      assert :crlf == List.last(tokens)
      # Verify the structure has the right number of parens
      lparen_count = Enum.count(tokens, &(&1 == :lparen))
      rparen_count = Enum.count(tokens, &(&1 == :rparen))
      assert lparen_count == rparen_count
    end
  end

  describe "edge cases" do
    test "keyword flag atoms (not backslash-prefixed)" do
      # RFC 9051: flag-keyword = "$MDNSent" / "$Forwarded" / ... / atom
      assert {:ok, [{:atom, "$MDNSent"}, :crlf], ""} = Tokenizer.tokenize("$MDNSent\r\n")
    end

    test "response with PERMANENTFLAGS including \\*" do
      input = "* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n"

      assert {:ok, tokens, ""} = Tokenizer.tokenize(input)
      assert {:flag, "\\*"} in tokens
      assert {:flag, "\\Deleted"} in tokens
      assert {:flag, "\\Seen"} in tokens
    end

    test "NIL in list context" do
      input = "* LIST () NIL INBOX\r\n"

      assert {:ok,
              [
                :star,
                {:atom, "LIST"},
                :lparen,
                :rparen,
                :nil,
                {:atom, "INBOX"},
                :crlf
              ], ""} = Tokenizer.tokenize(input)
    end

    test "angle brackets in BODY response" do
      # RFC 9051: "BODY" section ["<" number ">"] SP nstring
      input = "* 1 FETCH (BODY[]<0> \"data\")\r\n"

      assert {:ok, tokens, ""} = Tokenizer.tokenize(input)
      # < and > are atom chars, so <0> will be tokenized as part of surrounding content
      assert :star == hd(tokens)
    end
  end
end
