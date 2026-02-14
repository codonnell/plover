defmodule Plover.Protocol.Tokenizer do
  @moduledoc """
  Tokenizes IMAP response lines from binary data into a token stream.

  Uses NimbleParsec for compile-time parser generation. The generated code
  is pure binary pattern matching with no runtime dependency on NimbleParsec.

  RFC 9051 Section 9 - Formal Syntax
  """

  import NimbleParsec

  # RFC 9051: ATOM-CHAR = <any CHAR except atom-specials>
  # atom-specials = "(" / ")" / "{" / SP / CTL / list-wildcards / quoted-specials / resp-specials
  # list-wildcards = "%" / "*"
  # quoted-specials = DQUOTE / "\"
  # resp-specials = "]"
  # Allowed: printable ASCII 0x21-0x7E except ( ) { % * " \ ]
  atom_char =
    utf8_char([
      0x21,         # !
      0x23..0x27,   # # $ % & '
      0x2B..0x2F,   # + , - . /
      0x30..0x39,   # 0-9
      0x3A..0x3F,   # : ; < = > ?
      0x40,         # @
      0x41..0x5A,   # A-Z
      0x5E..0x60,   # ^ _ `
      0x61..0x7A,   # a-z
      0x7C,         # |
      0x7E          # ~
    ])

  # Flag: "\" followed by atom chars OR "\*"
  # RFC 9051: flag-perm = flag / "\*"
  flag_token =
    string("\\")
    |> choice([
      string("*"),
      times(atom_char, min: 1) |> reduce({List, :to_string, []})
    ])
    |> reduce({Enum, :join, []})
    |> unwrap_and_tag(:flag)

  # Number: 1+ digits, converted to integer
  number_token =
    times(utf8_char([?0..?9]), min: 1)
    |> reduce({List, :to_string, []})
    |> map({String, :to_integer, []})
    |> unwrap_and_tag(:number)

  # NIL keyword - must match before general atom
  nil_token =
    string("NIL")
    |> lookahead_not(atom_char)
    |> replace(:nil)

  # Atom: 1+ ATOM-CHARs
  atom_token =
    times(atom_char, min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:atom)

  # Quoted string: DQUOTE *QUOTED-CHAR DQUOTE
  # QUOTED-CHAR = <any TEXT-CHAR except quoted-specials> / "\" quoted-specials
  escaped_char =
    ignore(string("\\"))
    |> utf8_char([?", ?\\])

  regular_char =
    utf8_char([{:not, ?\r}, {:not, ?\n}, {:not, ?"}, {:not, ?\\}])

  quoted_string =
    ignore(string("\""))
    |> repeat(choice([escaped_char, regular_char]))
    |> ignore(string("\""))
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:quoted_string)

  # Literal header: "{" number ["+"] "}" CRLF
  # The actual data bytes are consumed via post_traverse
  literal_header =
    ignore(string("{"))
    |> concat(
      times(utf8_char([?0..?9]), min: 1)
      |> reduce({List, :to_string, []})
      |> map({String, :to_integer, []})
    )
    |> optional(string("+") |> replace(:non_sync))
    |> ignore(string("}"))
    |> ignore(string("\r\n"))
    |> post_traverse({:consume_literal_bytes, []})

  # A single non-CRLF token
  non_crlf_token =
    choice([
      ignore(string(" ")),
      string("(") |> replace(:lparen),
      string(")") |> replace(:rparen),
      string("[") |> replace(:lbracket),
      string("]") |> replace(:rbracket),
      flag_token,
      quoted_string,
      literal_header,
      nil_token,
      number_token,
      string("*") |> replace(:star),
      string("+") |> replace(:plus),
      atom_token
    ])

  # A complete response line: tokens terminated by CRLF
  response_line =
    repeat(non_crlf_token)
    |> concat(string("\r\n") |> replace(:crlf))

  defparsec(:parse_line, response_line, inline: true)

  @doc """
  Tokenize one IMAP response line from binary data.

  Returns `{:ok, tokens, rest}` on success, or `{:error, reason}` on failure.
  Parses one complete response line (up to and including CRLF).
  Any data after the CRLF is returned as `rest`.
  """
  @spec tokenize(binary()) :: {:ok, list(), binary()} | {:error, term()}
  def tokenize(data) when is_binary(data) do
    case parse_line(data) do
      {:ok, tokens, rest, _context, _line, _column} ->
        {:ok, tokens, rest}

      {:error, message, _rest, _context, _line, _column} ->
        {:error, message}
    end
  end

  # Post-traverse callback for consuming literal bytes after {N}\r\n
  defp consume_literal_bytes(rest, results, context, _line, _column) do
    size =
      case results do
        [size] when is_integer(size) -> size
        [:non_sync, size] when is_integer(size) -> size
      end

    if byte_size(rest) >= size do
      <<data::binary-size(size), remaining::binary>> = rest
      {remaining, [{:literal, data}], context}
    else
      {:error, "incomplete literal: need #{size} bytes, have #{byte_size(rest)}"}
    end
  end
end
