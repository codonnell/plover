defmodule Plover.Content do
  @moduledoc """
  Content-Transfer-Encoding decoding and charset conversion for email body parts.

  Decodes base64 and quoted-printable transfer encodings as specified in
  RFC 2045, and converts common charsets to UTF-8 using only OTP stdlib.

  ## Examples

      # Decode base64 content
      {:ok, binary} = Plover.Content.decode(raw, "BASE64")

      # Decode quoted-printable with charset conversion
      {:ok, text} = Plover.Content.decode(raw, "QUOTED-PRINTABLE", "ISO-8859-1")

      # Decode and convert in one step
      {:ok, utf8_text} = Plover.Content.decode(raw, "BASE64", "Windows-1252")
  """

  @encoded_word_re ~r/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/

  @doc """
  Decode RFC 2047 encoded-words in a header value.

  Encoded-words have the form `=?charset?encoding?text?=` where encoding is
  `B` (base64) or `Q` (quoted-printable with `_` for space). Adjacent
  encoded-words separated only by whitespace are concatenated per RFC 2047
  Section 6.2.

  Returns the decoded string. Passes through `nil` and plain strings
  that contain no encoded-words.
  """
  @spec decode_encoded_words(String.t() | nil) :: String.t() | nil
  def decode_encoded_words(nil), do: nil
  def decode_encoded_words(""), do: ""

  def decode_encoded_words(text) do
    # Collapse whitespace between adjacent encoded-words (RFC 2047 §6.2)
    collapsed = Regex.replace(~r/\?=\s+=\?/, text, "?==?")

    result =
      Regex.split(@encoded_word_re, collapsed, include_captures: true)
      |> Enum.map_join(fn part ->
        case Regex.run(@encoded_word_re, part) do
          [_, charset, encoding, encoded_text] ->
            decode_word(charset, encoding, encoded_text)

          _ ->
            part
        end
      end)

    result
  end

  defp decode_word(charset, encoding, text) do
    decoded =
      case String.upcase(encoding) do
        "B" ->
          case Base.decode64(text) do
            {:ok, bytes} -> bytes
            :error -> text
          end

        "Q" ->
          text
          |> String.replace("_", " ")
          |> decode_qp(<<>>)
      end

    convert_charset(decoded, charset)
  end

  @doc """
  Decode content using the specified transfer encoding.

  Supported encodings: `"BASE64"`, `"QUOTED-PRINTABLE"`, `"7BIT"`, `"8BIT"`, `"BINARY"`.
  Encoding names are case-insensitive.
  """
  @spec decode(binary(), String.t()) :: {:ok, binary()} | {:error, term()}
  def decode(data, encoding) do
    case String.upcase(encoding) do
      "BASE64" -> decode_base64(data)
      "QUOTED-PRINTABLE" -> decode_quoted_printable(data)
      "7BIT" -> {:ok, data}
      "8BIT" -> {:ok, data}
      "BINARY" -> {:ok, data}
      other -> {:error, {:unknown_encoding, other}}
    end
  end

  @doc """
  Decode content using the specified transfer encoding, then convert
  from the given charset to UTF-8.
  """
  @spec decode(binary(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def decode(data, encoding, charset) do
    with {:ok, decoded} <- decode(data, encoding) do
      {:ok, convert_charset(decoded, charset)}
    end
  end

  @doc """
  Decode base64 encoded data. Whitespace (line breaks) is ignored.
  """
  @spec decode_base64(binary()) :: {:ok, binary()} | {:error, term()}
  def decode_base64(""), do: {:ok, ""}

  def decode_base64(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  @doc """
  Decode quoted-printable encoded data per RFC 2045 Section 6.7.

  - `=XX` hex pairs are decoded to the corresponding byte
  - Soft line breaks (`=\\r\\n` or `=\\n`) are removed
  - All other characters pass through unchanged
  """
  @spec decode_quoted_printable(binary()) :: {:ok, binary()} | {:error, term()}
  def decode_quoted_printable(data) do
    {:ok, decode_qp(data, <<>>)}
  end

  defp decode_qp(<<>>, acc), do: acc

  defp decode_qp(<<?=, ?\r, ?\n, rest::binary>>, acc) do
    decode_qp(rest, acc)
  end

  defp decode_qp(<<?=, ?\n, rest::binary>>, acc) do
    decode_qp(rest, acc)
  end

  defp decode_qp(<<?=, hi, lo, rest::binary>>, acc)
       when (hi in ?0..?9 or hi in ?A..?F or hi in ?a..?f) and
              (lo in ?0..?9 or lo in ?A..?F or lo in ?a..?f) do
    byte = hex_to_int(hi) * 16 + hex_to_int(lo)
    decode_qp(rest, <<acc::binary, byte>>)
  end

  defp decode_qp(<<?=, rest::binary>>, acc) do
    decode_qp(rest, <<acc::binary, ?=>>)
  end

  defp decode_qp(<<byte, rest::binary>>, acc) do
    decode_qp(rest, <<acc::binary, byte>>)
  end

  defp hex_to_int(c) when c in ?0..?9, do: c - ?0
  defp hex_to_int(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_to_int(c) when c in ?a..?f, do: c - ?a + 10

  @doc """
  Convert binary data from the given charset to UTF-8.

  Supported charsets: UTF-8, US-ASCII, ISO-8859-1 (Latin-1), Windows-1252.
  Unknown charsets return the data unchanged.
  """
  @spec convert_charset(binary(), String.t()) :: binary()
  def convert_charset(data, charset) do
    case String.upcase(charset) do
      c when c in ["UTF-8", "UTF8", "US-ASCII", "ASCII"] ->
        data

      c when c in ["ISO-8859-1", "LATIN-1", "LATIN1"] ->
        latin1_to_utf8(data)

      c when c in ["WINDOWS-1252", "CP1252"] ->
        windows1252_to_utf8(data)

      _ ->
        data
    end
  end

  defp latin1_to_utf8(data) do
    for <<byte <- data>>, into: <<>>, do: <<byte::utf8>>
  end

  # Windows-1252 differs from ISO-8859-1 in the 0x80-0x9F range
  @win1252_map %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp windows1252_to_utf8(data) do
    for <<byte <- data>>, into: <<>> do
      case Map.get(@win1252_map, byte) do
        nil -> <<byte::utf8>>
        codepoint -> <<codepoint::utf8>>
      end
    end
  end
end
