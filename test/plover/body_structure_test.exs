defmodule Plover.BodyStructureTest do
  use ExUnit.Case, async: true

  alias Plover.BodyStructure, as: BS
  alias Plover.Response.BodyStructure

  # --- Test fixtures ---

  defp text_plain do
    %BodyStructure{
      type: "TEXT",
      subtype: "PLAIN",
      params: %{"CHARSET" => "UTF-8"},
      encoding: "7BIT",
      size: 100,
      lines: 5
    }
  end

  defp text_html do
    %BodyStructure{
      type: "TEXT",
      subtype: "HTML",
      params: %{"CHARSET" => "UTF-8"},
      encoding: "QUOTED-PRINTABLE",
      size: 500,
      lines: 20
    }
  end

  defp pdf_attachment do
    %BodyStructure{
      type: "APPLICATION",
      subtype: "PDF",
      params: %{"NAME" => "report.pdf"},
      encoding: "BASE64",
      size: 45678,
      disposition: {"ATTACHMENT", %{"FILENAME" => "report.pdf"}}
    }
  end

  defp image_inline do
    %BodyStructure{
      type: "IMAGE",
      subtype: "PNG",
      params: %{},
      encoding: "BASE64",
      size: 12345,
      disposition: {"INLINE", %{"FILENAME" => "logo.png"}}
    }
  end

  defp simple_message, do: text_plain()

  defp multipart_alternative do
    %BodyStructure{
      type: "multipart",
      subtype: "ALTERNATIVE",
      parts: [text_plain(), text_html()]
    }
  end

  defp multipart_mixed do
    %BodyStructure{
      type: "multipart",
      subtype: "MIXED",
      parts: [multipart_alternative(), pdf_attachment()]
    }
  end

  defp nested_multipart do
    %BodyStructure{
      type: "multipart",
      subtype: "MIXED",
      parts: [
        multipart_alternative(),
        pdf_attachment(),
        image_inline()
      ]
    }
  end

  # --- flatten/1 ---

  describe "flatten/1" do
    test "single-part message returns section 1" do
      assert [{section, part}] = BS.flatten(simple_message())
      assert section == "1"
      assert part.type == "TEXT"
      assert part.subtype == "PLAIN"
    end

    test "2-part alternative returns sections 1 and 2" do
      parts = BS.flatten(multipart_alternative())
      assert length(parts) == 2
      [{"1", plain}, {"2", html}] = parts
      assert plain.subtype == "PLAIN"
      assert html.subtype == "HTML"
    end

    test "nested multipart returns dot-separated sections" do
      parts = BS.flatten(multipart_mixed())
      assert length(parts) == 3

      sections = Enum.map(parts, fn {s, _} -> s end)
      assert sections == ["1.1", "1.2", "2"]

      [{_, plain}, {_, html}, {_, pdf}] = parts
      assert plain.subtype == "PLAIN"
      assert html.subtype == "HTML"
      assert pdf.subtype == "PDF"
    end

    test "3-level nested multipart" do
      deep = %BodyStructure{
        type: "multipart",
        subtype: "MIXED",
        parts: [
          %BodyStructure{
            type: "multipart",
            subtype: "RELATED",
            parts: [
              multipart_alternative(),
              image_inline()
            ]
          },
          pdf_attachment()
        ]
      }

      parts = BS.flatten(deep)
      sections = Enum.map(parts, fn {s, _} -> s end)
      assert sections == ["1.1.1", "1.1.2", "1.2", "2"]
    end

    test "only returns leaf parts (no multipart containers)" do
      parts = BS.flatten(nested_multipart())

      for {_section, part} <- parts do
        refute part.type == "multipart"
      end
    end
  end

  # --- find_parts/2 ---

  describe "find_parts/2" do
    test "exact MIME type match" do
      results = BS.find_parts(multipart_mixed(), "text/plain")
      assert length(results) == 1
      [{section, part}] = results
      assert section == "1.1"
      assert part.subtype == "PLAIN"
    end

    test "wildcard subtype match" do
      results = BS.find_parts(multipart_mixed(), "text/*")
      assert length(results) == 2
      sections = Enum.map(results, fn {s, _} -> s end)
      assert "1.1" in sections
      assert "1.2" in sections
    end

    test "case-insensitive matching" do
      results = BS.find_parts(multipart_mixed(), "TEXT/PLAIN")
      assert length(results) == 1
    end

    test "no match returns empty list" do
      assert [] = BS.find_parts(multipart_mixed(), "audio/mpeg")
    end

    test "matches on single-part message" do
      results = BS.find_parts(simple_message(), "text/plain")
      assert length(results) == 1
      [{"1", part}] = results
      assert part.type == "TEXT"
    end

    test "application wildcard" do
      results = BS.find_parts(multipart_mixed(), "application/*")
      assert length(results) == 1
      [{_, part}] = results
      assert part.subtype == "PDF"
    end
  end

  # --- attachments/1 ---

  describe "attachments/1" do
    test "returns no attachments for simple text message" do
      assert [] = BS.attachments(simple_message())
    end

    test "returns attachment with disposition ATTACHMENT" do
      result = BS.attachments(multipart_mixed())
      assert length(result) == 1
      [att] = result
      assert att.section == "2"
      assert att.filename == "report.pdf"
      assert att.type == "APPLICATION/PDF"
      assert att.size == 45678
      assert att.encoding == "BASE64"
    end

    test "excludes inline disposition" do
      result = BS.attachments(nested_multipart())
      # Only the PDF attachment, not the inline image
      assert length(result) == 1
      [att] = result
      assert att.filename == "report.pdf"
    end

    test "detects attachment from body params filename when no disposition" do
      bs = %BodyStructure{
        type: "multipart",
        subtype: "MIXED",
        parts: [
          text_plain(),
          %BodyStructure{
            type: "APPLICATION",
            subtype: "OCTET-STREAM",
            params: %{"NAME" => "data.bin"},
            encoding: "BASE64",
            size: 1000
          }
        ]
      }

      result = BS.attachments(bs)
      assert length(result) == 1
      [att] = result
      assert att.filename == "data.bin"
      assert att.section == "2"
    end

    test "returns multiple attachments" do
      bs = %BodyStructure{
        type: "multipart",
        subtype: "MIXED",
        parts: [
          text_plain(),
          pdf_attachment(),
          %BodyStructure{
            type: "IMAGE",
            subtype: "JPEG",
            params: %{},
            encoding: "BASE64",
            size: 9999,
            disposition: {"ATTACHMENT", %{"FILENAME" => "photo.jpg"}}
          }
        ]
      }

      result = BS.attachments(bs)
      assert length(result) == 2
      filenames = Enum.map(result, & &1.filename)
      assert "report.pdf" in filenames
      assert "photo.jpg" in filenames
    end
  end

  # --- get_part/2 ---

  describe "get_part/2" do
    test "empty string returns root single-part" do
      assert {:ok, part} = BS.get_part(simple_message(), "")
      assert part.type == "TEXT"
    end

    test "section 1 in multipart alternative" do
      assert {:ok, part} = BS.get_part(multipart_alternative(), "1")
      assert part.subtype == "PLAIN"
    end

    test "section 2 in multipart alternative" do
      assert {:ok, part} = BS.get_part(multipart_alternative(), "2")
      assert part.subtype == "HTML"
    end

    test "nested section 1.1" do
      assert {:ok, part} = BS.get_part(multipart_mixed(), "1.1")
      assert part.subtype == "PLAIN"
    end

    test "nested section 1.2" do
      assert {:ok, part} = BS.get_part(multipart_mixed(), "1.2")
      assert part.subtype == "HTML"
    end

    test "nested section 2" do
      assert {:ok, part} = BS.get_part(multipart_mixed(), "2")
      assert part.subtype == "PDF"
    end

    test "invalid section returns error" do
      assert :error = BS.get_part(multipart_mixed(), "99")
    end

    test "invalid nested section returns error" do
      assert :error = BS.get_part(multipart_mixed(), "1.99")
    end
  end

  # --- charset/1 ---

  describe "charset/1" do
    test "returns charset from params" do
      assert BS.charset(text_plain()) == "UTF-8"
    end

    test "returns default US-ASCII when no params" do
      bs = %BodyStructure{type: "TEXT", subtype: "PLAIN", params: %{}}
      assert BS.charset(bs) == "US-ASCII"
    end

    test "returns default US-ASCII when params nil" do
      bs = %BodyStructure{type: "TEXT", subtype: "PLAIN"}
      assert BS.charset(bs) == "US-ASCII"
    end

    test "case-insensitive key lookup" do
      bs = %BodyStructure{type: "TEXT", subtype: "PLAIN", params: %{"charset" => "ISO-8859-1"}}
      assert BS.charset(bs) == "ISO-8859-1"
    end
  end

  # --- encoding/1 ---

  describe "encoding/1" do
    test "returns encoding from struct" do
      assert BS.encoding(text_html()) == "QUOTED-PRINTABLE"
    end

    test "returns default 7BIT when nil" do
      bs = %BodyStructure{type: "TEXT", subtype: "PLAIN"}
      assert BS.encoding(bs) == "7BIT"
    end
  end
end
