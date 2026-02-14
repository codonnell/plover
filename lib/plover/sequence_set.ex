defmodule Plover.SequenceSet do
  @moduledoc """
  Parse and format IMAP sequence sets.

  RFC 9051 Section 9 Formal Syntax:
    sequence-set    = (seq-number / seq-range) ["," sequence-set]
    seq-range       = seq-number ":" seq-number
    seq-number      = nz-number / "*"
    nz-number       = digit-nz *DIGIT
  """

  @typedoc "A single range in a sequence set, where both endpoints may be `:star`."
  @type range :: {Plover.Types.seq_number(), Plover.Types.seq_number()}

  @doc """
  Parses an IMAP sequence set string into a list of range tuples.

  Single numbers become `{n, n}` tuples. The wildcard `*` becomes `:star`.

  ## Examples

      iex> Plover.SequenceSet.parse("1:5")
      {:ok, [{1, 5}]}

      iex> Plover.SequenceSet.parse("1,3:5,10:*")
      {:ok, [{1, 1}, {3, 5}, {10, :star}]}

  """
  @spec parse(String.t()) :: {:ok, [range()]} | {:error, :invalid}
  def parse(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> parse_parts([])
  end

  defp parse_parts([], acc) when acc != [], do: {:ok, Enum.reverse(acc)}
  defp parse_parts([], _acc), do: {:error, :invalid}

  defp parse_parts([part | rest], acc) do
    case parse_range(part) do
      {:ok, range} -> parse_parts(rest, [range | acc])
      :error -> {:error, :invalid}
    end
  end

  defp parse_range(str) do
    case String.split(str, ":", parts: 2) do
      [a, b] ->
        with {:ok, from} <- parse_seq_number(a),
             {:ok, to} <- parse_seq_number(b) do
          {:ok, {from, to}}
        end

      [a] ->
        with {:ok, num} <- parse_seq_number(a) do
          {:ok, {num, num}}
        end
    end
  end

  defp parse_seq_number("*"), do: {:ok, :star}

  defp parse_seq_number(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  @doc """
  Formats a list of range tuples into an IMAP sequence set string.

  ## Examples

      iex> Plover.SequenceSet.format([{1, 5}, {10, :star}])
      "1:5,10:*"

      iex> Plover.SequenceSet.format([{3, 3}])
      "3"

  """
  @spec format([range()]) :: String.t()
  def format(ranges) when is_list(ranges) do
    ranges
    |> Enum.map(&format_range/1)
    |> Enum.join(",")
  end

  defp format_range({n, n}), do: format_seq_number(n)
  defp format_range({from, to}), do: "#{format_seq_number(from)}:#{format_seq_number(to)}"

  defp format_seq_number(:star), do: "*"
  defp format_seq_number(n) when is_integer(n), do: Integer.to_string(n)
end
