defmodule Plover.ContentTest do
  use ExUnit.Case, async: true

  alias Plover.Content

  describe "decode_base64/1" do
    test "decodes standard base64" do
      encoded = Base.encode64("Hello, World!")
      assert {:ok, "Hello, World!"} = Content.decode_base64(encoded)
    end

    test "decodes base64 with line breaks" do
      # Base64 with CRLF line breaks (as in MIME)
      raw = "SGVsbG8s\r\nIFdvcmxkIQ=="
      assert {:ok, "Hello, World!"} = Content.decode_base64(raw)
    end

    test "decodes empty string" do
      assert {:ok, ""} = Content.decode_base64("")
    end

    test "returns error for invalid base64" do
      assert {:error, _} = Content.decode_base64("!!!not-base64!!!")
    end
  end

  describe "decode_quoted_printable/1" do
    test "decodes =XX hex sequences" do
      assert {:ok, "café"} = Content.decode_quoted_printable("caf=C3=A9")
    end

    test "removes soft line breaks (=CRLF)" do
      assert {:ok, "hello world"} = Content.decode_quoted_printable("hello =\r\nworld")
    end

    test "removes soft line breaks (=LF only)" do
      assert {:ok, "hello world"} = Content.decode_quoted_printable("hello =\nworld")
    end

    test "passes through plain text" do
      assert {:ok, "Hello, World!"} = Content.decode_quoted_printable("Hello, World!")
    end

    test "decodes high bytes" do
      # Latin-1 encoded ü (0xFC)
      assert {:ok, <<0xFC>>} = Content.decode_quoted_printable("=FC")
    end

    test "handles lowercase hex" do
      assert {:ok, <<0xFC>>} = Content.decode_quoted_printable("=fc")
    end

    test "decodes mixed content" do
      input = "Subject: =C3=A9t=C3=A9 2024=\r\n is here"
      {:ok, decoded} = Content.decode_quoted_printable(input)
      assert decoded == "Subject: été 2024 is here"
    end

    test "preserves CRLF line endings" do
      assert {:ok, "line1\r\nline2"} = Content.decode_quoted_printable("line1\r\nline2")
    end

    test "empty string" do
      assert {:ok, ""} = Content.decode_quoted_printable("")
    end

    test "passes through bare = followed by non-hex characters" do
      input = "https://example.com?q=unknown"
      assert {:ok, ^input} = Content.decode_quoted_printable(input)
    end

    test "passes through bare = at end of string" do
      assert {:ok, "trailing="} = Content.decode_quoted_printable("trailing=")
    end

    test "handles mix of valid hex pairs and bare = with non-hex" do
      input = "=C3=A9 and q=unknown"
      {:ok, decoded} = Content.decode_quoted_printable(input)
      assert decoded == "é and q=unknown"
    end
  end

  describe "convert_charset/2" do
    test "UTF-8 passthrough" do
      assert {:ok, "hello"} = Content.convert_charset("hello", "UTF-8")
    end

    test "utf-8 lowercase passthrough" do
      assert {:ok, "hello"} = Content.convert_charset("hello", "utf-8")
    end

    test "US-ASCII passthrough" do
      assert {:ok, "hello"} = Content.convert_charset("hello", "US-ASCII")
    end

    test "ISO-8859-1 to UTF-8" do
      # ü in Latin-1 is 0xFC
      latin1 = <<0xFC>>
      {:ok, result} = Content.convert_charset(latin1, "ISO-8859-1")
      assert result == "ü"
    end

    test "ISO-8859-1 mixed ASCII and high bytes" do
      # Héllo
      latin1 = <<0x48, 0xE9, 0x6C, 0x6C, 0x6F>>
      {:ok, result} = Content.convert_charset(latin1, "ISO-8859-1")
      assert result == "Héllo"
    end

    test "case-insensitive charset name" do
      latin1 = <<0xFC>>
      {:ok, result} = Content.convert_charset(latin1, "iso-8859-1")
      assert result == "ü"
    end

    test "Windows-1252 to UTF-8 for standard range" do
      latin1 = <<0xFC>>
      {:ok, result} = Content.convert_charset(latin1, "Windows-1252")
      assert result == "ü"
    end

    test "Windows-1252 special characters (0x80-0x9F)" do
      # 0x80 = €, 0x93 = left double quote, 0x94 = right double quote
      win = <<0x80, 0x93, 0x94>>
      {:ok, result} = Content.convert_charset(win, "Windows-1252")
      assert result == "\u20AC\u201C\u201D"
    end

    test "unknown charset returns data as-is" do
      assert {:ok, "data"} = Content.convert_charset("data", "X-UNKNOWN-CHARSET")
    end
  end

  describe "decode_encoded_words/1" do
    test "decodes a single base64 encoded-word" do
      input = "=?UTF-8?B?SGVsbG8=?="
      assert {:ok, "Hello"} = Content.decode_encoded_words(input)
    end

    test "decodes a single Q encoded-word" do
      input = "=?UTF-8?Q?caf=C3=A9?="
      assert {:ok, "café"} = Content.decode_encoded_words(input)
    end

    test "Q encoding replaces underscores with spaces" do
      input = "=?UTF-8?Q?Hello_World?="
      assert {:ok, "Hello World"} = Content.decode_encoded_words(input)
    end

    test "concatenates adjacent encoded-words, dropping whitespace between them" do
      input =
        "=?UTF-8?B?SGVhbHRoIGNhcmUgY29zdHMgYXJlIG9uIHRoZSByaXNlIOKAlCBi?= =?UTF-8?B?ZSByZWFkeSB0byBtZWV0IHRoZW0=?="

      assert {:ok, decoded} = Content.decode_encoded_words(input)
      assert decoded == "Health care costs are on the rise — be ready to meet them"
    end

    test "concatenates adjacent encoded-words separated by newline and space (folding)" do
      input =
        "=?UTF-8?B?SGVsbG8=?=\r\n =?UTF-8?B?V29ybGQ=?="

      assert {:ok, "HelloWorld"} = Content.decode_encoded_words(input)
    end

    test "preserves text around encoded-words" do
      input = "Re: =?UTF-8?B?Y2Fmw6k=?= was great"
      assert {:ok, "Re: café was great"} = Content.decode_encoded_words(input)
    end

    test "returns plain text unchanged" do
      input = "Just a normal subject"
      assert {:ok, ^input} = Content.decode_encoded_words(input)
    end

    test "handles ISO-8859-1 charset" do
      # 0xE9 = é in Latin-1
      input = "=?ISO-8859-1?Q?caf=E9?="
      assert {:ok, "café"} = Content.decode_encoded_words(input)
    end

    test "handles case-insensitive encoding and charset" do
      input = "=?utf-8?b?SGVsbG8=?="
      assert {:ok, "Hello"} = Content.decode_encoded_words(input)
    end

    test "handles empty string" do
      assert {:ok, ""} = Content.decode_encoded_words("")
    end

    test "handles nil" do
      assert {:ok, nil} = Content.decode_encoded_words(nil)
    end
  end

  describe "decode/2 (encoding only)" do
    test "BASE64" do
      encoded = Base.encode64("test data")
      assert {:ok, "test data"} = Content.decode(encoded, "BASE64")
    end

    test "QUOTED-PRINTABLE" do
      assert {:ok, "café"} = Content.decode("caf=C3=A9", "QUOTED-PRINTABLE")
    end

    test "7BIT passthrough" do
      assert {:ok, "hello"} = Content.decode("hello", "7BIT")
    end

    test "8BIT passthrough" do
      assert {:ok, "hello"} = Content.decode("hello", "8BIT")
    end

    test "BINARY passthrough" do
      assert {:ok, "hello"} = Content.decode("hello", "BINARY")
    end

    test "case-insensitive encoding" do
      encoded = Base.encode64("test")
      assert {:ok, "test"} = Content.decode(encoded, "base64")
    end
  end

  describe "decode/3 (encoding + charset)" do
    test "BASE64 with UTF-8" do
      encoded = Base.encode64("hello")
      assert {:ok, "hello"} = Content.decode(encoded, "BASE64", "UTF-8")
    end

    test "QUOTED-PRINTABLE with ISO-8859-1" do
      # =FC is ü in Latin-1
      {:ok, result} = Content.decode("=FC", "QUOTED-PRINTABLE", "ISO-8859-1")
      assert result == "ü"
    end

    test "7BIT with US-ASCII" do
      assert {:ok, "hello"} = Content.decode("hello", "7BIT", "US-ASCII")
    end

    test "BASE64 with ISO-8859-1" do
      # Encode Latin-1 ü (0xFC) as base64
      encoded = Base.encode64(<<0xFC>>)
      {:ok, result} = Content.decode(encoded, "BASE64", "ISO-8859-1")
      assert result == "ü"
    end
  end
end
