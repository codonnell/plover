defmodule Plover.Protocol.CommandBuilder do
  @moduledoc """
  Serializes `%Command{}` structs to iodata for transmission over the wire.

  Handles IMAP astring quoting rules:
  - Atom: if all chars are ATOM-CHAR, send as-is
  - Quoted string: if contains spaces/parens/etc but no CR/LF, use quoted form
  - Literal: for data with CR/LF or binary content

  RFC 9051 Section 9 - Formal Syntax
  """

  alias Plover.Command

  @doc """
  Build an IMAP command into iodata ready for transmission.

  For most commands, returns iodata.
  For APPEND (which requires a literal), returns `{:literal, first_part, literal_data}`
  where `first_part` is iodata to send before the continuation, and `literal_data`
  is the binary to send after receiving the continuation response.
  """
  @spec build(Command.t()) :: iodata() | {:literal, iodata(), binary()}
  def build(%Command{tag: tag, name: name, args: args}) do
    case find_literal(args) do
      nil ->
        build_simple(tag, name, args)

      {pre_args, literal_data, _post_args} ->
        size = byte_size(literal_data)
        first_part = [tag, " ", name | encode_args(pre_args)] ++ [" {", Integer.to_string(size), "}\r\n"]
        {:literal, first_part, literal_data}
    end
  end

  @doc """
  Build the DONE command for ending IDLE.
  """
  @spec build_done() :: iodata()
  def build_done, do: "DONE\r\n"

  defp build_simple(tag, name, []) do
    [tag, " ", name, "\r\n"]
  end

  defp build_simple(tag, name, args) do
    [tag, " ", name | encode_args(args)] ++ ["\r\n"]
  end

  defp encode_args(args) do
    Enum.map(args, fn arg -> [" ", encode_arg(arg)] end)
  end

  defp encode_arg({:literal, _data} = lit), do: lit
  defp encode_arg({:raw, data}), do: data
  defp encode_arg(arg) when is_binary(arg), do: encode_astring(arg)
  defp encode_arg(arg) when is_integer(arg), do: Integer.to_string(arg)
  defp encode_arg(arg), do: to_string(arg)

  # RFC 9051: astring = 1*ASTRING-CHAR / string
  # ASTRING-CHAR = ATOM-CHAR / resp-specials
  # If safe for atom, send as-is. If needs quoting, use quoted string.
  defp encode_astring(""), do: "\"\""

  defp encode_astring(str) do
    if atom_safe?(str) do
      str
    else
      quote_string(str)
    end
  end

  # Check if all characters are ATOM-CHAR or resp-specials (])
  # Also allow: *, %, which appear in LIST patterns and flags
  defp atom_safe?(str) do
    str
    |> String.to_charlist()
    |> Enum.all?(&atom_char?/1)
  end

  # ATOM-CHAR: printable ASCII except ( ) { SP % " \
  # But for command building, we allow *, %, \, ], [, <, > for patterns, flags, sections
  # We only need to quote when there are spaces, parens, braces, or control chars
  defp atom_char?(c) when c in [?\s, ?(, ?), ?{], do: false
  defp atom_char?(c) when c < 0x20, do: false
  defp atom_char?(0x7F), do: false
  defp atom_char?(c) when c == ?", do: false
  defp atom_char?(_), do: true

  defp quote_string(str) do
    escaped =
      str
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    [?", escaped, ?"]
  end

  # Find a literal in the args list, returning {pre_args, literal_data, post_args}
  defp find_literal(args), do: find_literal(args, [])

  defp find_literal([], _pre), do: nil

  defp find_literal([{:literal, data} | post], pre) do
    {Enum.reverse(pre), data, post}
  end

  defp find_literal([arg | rest], pre) do
    find_literal(rest, [arg | pre])
  end
end
