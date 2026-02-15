defmodule Plover.Protocol.ParserPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Plover.Protocol.{Tokenizer, Parser}

  # Generate a valid IMAP tag (like A0001)
  defp tag_string do
    gen all(n <- StreamData.integer(1..9999)) do
      "A" <> String.pad_leading(Integer.to_string(n), 4, "0")
    end
  end

  # Generate OK/NO/BAD status
  defp status_atom do
    StreamData.member_of(["OK", "NO", "BAD"])
  end

  # Generate simple response text (no special chars)
  defp response_text do
    gen all(
          str <-
            StreamData.string(
              Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ [?\s],
              min_length: 1,
              max_length: 30
            )
        ) do
      String.trim(str)
    end
  end

  property "tagged responses parse correctly" do
    check all(
            tag <- tag_string(),
            status <- status_atom(),
            text <- response_text(),
            text != ""
          ) do
      line = "#{tag} #{status} #{text}\r\n"
      {:ok, tokens, _} = Tokenizer.tokenize(line)
      {:ok, response} = Parser.parse(tokens)
      assert response.tag == tag
      assert response.status == status_to_atom(status)
      assert is_binary(response.text)
    end
  end

  property "untagged EXISTS responses parse correctly" do
    check all(count <- StreamData.positive_integer()) do
      line = "* #{count} EXISTS\r\n"
      {:ok, tokens, _} = Tokenizer.tokenize(line)
      {:ok, response} = Parser.parse(tokens)
      assert response.count == count
    end
  end

  property "untagged EXPUNGE responses parse correctly" do
    check all(seq <- StreamData.positive_integer()) do
      line = "* #{seq} EXPUNGE\r\n"
      {:ok, tokens, _} = Tokenizer.tokenize(line)
      {:ok, response} = Parser.parse(tokens)
      assert response.seq == seq
    end
  end

  defp status_to_atom("OK"), do: :ok
  defp status_to_atom("NO"), do: :no
  defp status_to_atom("BAD"), do: :bad
end
