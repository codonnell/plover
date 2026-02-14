defmodule Plover.Protocol.TokenizerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Plover.Protocol.Tokenizer

  # Generate valid atom strings (ATOM-CHAR only, no digits-only which become numbers)
  defp atom_string do
    gen all(
          first <- StreamData.member_of(Enum.to_list(?A..?Z) ++ Enum.to_list(?a..?z)),
          rest <-
            StreamData.list_of(
              StreamData.member_of(
                Enum.to_list(?A..?Z) ++
                  Enum.to_list(?a..?z) ++
                  Enum.to_list(?0..?9) ++
                  ~c".-_/!#$&'+,:;<=>?@^`|~"
              ),
              min_length: 0,
              max_length: 20
            )
        ) do
      List.to_string([first | rest])
    end
  end

  # Generate valid IMAP atom strings that won't be "NIL"
  defp non_nil_atom_string do
    gen all(str <- atom_string(), str != "NIL") do
      str
    end
  end

  property "atoms round-trip through tokenization" do
    check all(atom_str <- non_nil_atom_string()) do
      input = atom_str <> "\r\n"
      assert {:ok, [{:atom, ^atom_str}, :crlf], ""} = Tokenizer.tokenize(input)
    end
  end

  property "numbers round-trip through tokenization" do
    check all(n <- StreamData.positive_integer()) do
      input = Integer.to_string(n) <> "\r\n"
      assert {:ok, [{:number, ^n}, :crlf], ""} = Tokenizer.tokenize(input)
    end
  end

  property "quoted strings round-trip through tokenization" do
    # Generate strings without CR, LF, quote, or backslash (simple case)
    check all(
            str <-
              StreamData.string(
                Enum.to_list(0x20..0x7E) -- [?", ?\\],
                min_length: 0,
                max_length: 50
              )
          ) do
      input = "\"#{str}\"\r\n"
      assert {:ok, [{:quoted_string, ^str}, :crlf], ""} = Tokenizer.tokenize(input)
    end
  end

  property "quoted strings with escapes round-trip" do
    check all(parts <- StreamData.list_of(StreamData.member_of(["hello", "\\\"", "\\\\"]), min_length: 1, max_length: 5)) do
      escaped = Enum.join(parts)
      input = "\"#{escaped}\"\r\n"
      {:ok, [{:quoted_string, unescaped}, :crlf], ""} = Tokenizer.tokenize(input)
      # The unescaped result should have \" -> " and \\ -> \
      expected = escaped |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
      assert unescaped == expected
    end
  end

  property "literals round-trip through tokenization" do
    # Generate binary data that doesn't need to be escaped
    check all(data <- StreamData.binary(min_length: 0, max_length: 100)) do
      size = byte_size(data)
      input = "{#{size}}\r\n#{data}\r\n"
      assert {:ok, [{:literal, ^data}, :crlf], ""} = Tokenizer.tokenize(input)
    end
  end

  property "system flags are tokenized correctly" do
    check all(
            flag_name <-
              StreamData.member_of([
                "Answered",
                "Flagged",
                "Deleted",
                "Seen",
                "Draft",
                "Recent"
              ])
          ) do
      flag = "\\#{flag_name}"
      input = flag <> "\r\n"
      assert {:ok, [{:flag, ^flag}, :crlf], ""} = Tokenizer.tokenize(input)
    end
  end
end
