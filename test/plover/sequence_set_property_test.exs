defmodule Plover.SequenceSetPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Plover.SequenceSet

  # Generate a valid sequence number or :star
  defp seq_number do
    StreamData.one_of([
      StreamData.positive_integer(),
      StreamData.constant(:star)
    ])
  end

  # Generate a sequence set element: either a single number or a range
  defp seq_element do
    StreamData.one_of([
      gen(all(n <- StreamData.positive_integer(), do: {n, n})),
      gen(all(from <- seq_number(), to <- seq_number(), do: {from, to}))
    ])
  end

  property "format then parse round-trips" do
    check all(
            elements <- StreamData.list_of(seq_element(), min_length: 1, max_length: 5)
          ) do
      formatted = SequenceSet.format(elements)
      assert is_binary(formatted)
      assert {:ok, parsed} = SequenceSet.parse(formatted)

      # Verify the round-trip produces equivalent elements
      assert length(parsed) == length(elements)

      Enum.zip(elements, parsed)
      |> Enum.each(fn {{from1, to1}, {from2, to2}} ->
        assert from1 == from2
        assert to1 == to2
      end)
    end
  end

  property "single numbers format as just the number" do
    check all(n <- StreamData.positive_integer()) do
      formatted = SequenceSet.format([{n, n}])
      assert formatted == Integer.to_string(n)
    end
  end

  property "ranges format with colon" do
    check all(
            from <- StreamData.integer(1..1000),
            to <- StreamData.integer(1001..2000)
          ) do
      formatted = SequenceSet.format([{from, to}])
      assert formatted == "#{from}:#{to}"
    end
  end

  property "star formats correctly" do
    check all(from <- StreamData.positive_integer()) do
      formatted = SequenceSet.format([{from, :star}])
      assert formatted == "#{from}:*"
    end
  end

  property "parsed sets have valid structure" do
    check all(
            nums <- StreamData.list_of(StreamData.positive_integer(), min_length: 1, max_length: 5)
          ) do
      # Build a comma-separated sequence set string
      str = Enum.join(nums, ",")
      assert {:ok, parsed} = SequenceSet.parse(str)
      assert length(parsed) == length(nums)

      Enum.each(parsed, fn {from, to} ->
        assert is_integer(from) or from == :star
        assert is_integer(to) or to == :star
      end)
    end
  end
end
