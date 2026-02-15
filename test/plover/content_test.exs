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
      latin1 = <<0x48, 0xE9, 0x6C, 0x6C, 0x6F>>  # Héllo
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
