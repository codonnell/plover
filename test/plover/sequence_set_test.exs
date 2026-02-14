defmodule Plover.SequenceSetTest do
  use ExUnit.Case, async: true
  doctest Plover.SequenceSet

  alias Plover.SequenceSet

  # RFC 9051 Section 9 - Formal Syntax
  # sequence-set = (seq-number / seq-range) ["," sequence-set]
  # seq-range = seq-number ":" seq-number
  # seq-number = nz-number / "*"

  describe "parse/1" do
    test "parses a single number" do
      assert SequenceSet.parse("1") == {:ok, [{1, 1}]}
    end

    test "parses a range" do
      assert SequenceSet.parse("1:5") == {:ok, [{1, 5}]}
    end

    test "parses wildcard star" do
      assert SequenceSet.parse("*") == {:ok, [{:star, :star}]}
    end

    test "parses range with star" do
      assert SequenceSet.parse("1:*") == {:ok, [{1, :star}]}
    end

    test "parses comma-separated set" do
      assert SequenceSet.parse("1,3,5") == {:ok, [{1, 1}, {3, 3}, {5, 5}]}
    end

    test "parses mixed ranges and numbers" do
      assert SequenceSet.parse("1:3,5,7:9") == {:ok, [{1, 3}, {5, 5}, {7, 9}]}
    end

    test "parses complex set" do
      assert SequenceSet.parse("1:3,5,7:*") == {:ok, [{1, 3}, {5, 5}, {7, :star}]}
    end

    test "returns error for invalid input" do
      assert SequenceSet.parse("") == {:error, :invalid}
      assert SequenceSet.parse("abc") == {:error, :invalid}
      assert SequenceSet.parse("0") == {:error, :invalid}
    end
  end

  describe "format/1" do
    test "formats a single number" do
      assert SequenceSet.format([{1, 1}]) == "1"
    end

    test "formats a range" do
      assert SequenceSet.format([{1, 5}]) == "1:5"
    end

    test "formats wildcard" do
      assert SequenceSet.format([{:star, :star}]) == "*"
    end

    test "formats range with star" do
      assert SequenceSet.format([{1, :star}]) == "1:*"
    end

    test "formats comma-separated set" do
      assert SequenceSet.format([{1, 1}, {3, 3}, {5, 5}]) == "1,3,5"
    end

    test "formats mixed ranges and numbers" do
      assert SequenceSet.format([{1, 3}, {5, 5}, {7, 9}]) == "1:3,5,7:9"
    end
  end

  describe "round-trip" do
    test "parse then format returns original" do
      inputs = ["1", "1:5", "*", "1:*", "1,3,5", "1:3,5,7:*"]

      for input <- inputs do
        {:ok, parsed} = SequenceSet.parse(input)
        assert SequenceSet.format(parsed) == input
      end
    end
  end
end
