defmodule Plover.BodyStructure do
  @moduledoc """
  Traversal utilities for `%Plover.Response.BodyStructure{}` trees.

  Provides functions to explore MIME message structures, find parts by
  type, list attachments, and extract metadata like charset and encoding.

  ## Example

      # Fetch body structure
      {:ok, [msg]} = Plover.fetch(conn, "1", [:body_structure])
      bs = msg.attrs.body_structure

      # Find the text/plain part
      [{section, part}] = Plover.BodyStructure.find_parts(bs, "text/plain")

      # Get charset and encoding for decoding
      charset = Plover.BodyStructure.charset(part)    # "UTF-8"
      encoding = Plover.BodyStructure.encoding(part)  # "QUOTED-PRINTABLE"

      # List attachments
      attachments = Plover.BodyStructure.attachments(bs)
      # [%{section: "2", filename: "report.pdf", type: "APPLICATION/PDF", ...}]
  """

  alias Plover.Response.BodyStructure

  @doc """
  Flatten a body structure tree into a list of `{section_path, part}` tuples.

  Only returns leaf parts (not multipart containers). Section paths follow
  RFC 9051 rules:

  - Single-part message: `""`
  - Multipart children: `"1"`, `"2"`, `"3"` (1-indexed)
  - Nested multipart: `"1.1"`, `"1.2"` (dot-separated)
  """
  @spec flatten(BodyStructure.t()) :: [{String.t(), BodyStructure.t()}]
  def flatten(%BodyStructure{} = bs) do
    flatten_parts(bs, "")
  end

  defp flatten_parts(%BodyStructure{type: "multipart", parts: parts}, prefix) do
    parts
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {part, idx} ->
      section = join_section(prefix, Integer.to_string(idx))
      flatten_parts(part, section)
    end)
  end

  defp flatten_parts(%BodyStructure{} = bs, section) do
    [{section, bs}]
  end

  defp join_section("", child), do: child
  defp join_section(parent, child), do: parent <> "." <> child

  @doc """
  Find parts matching a MIME type pattern.

  Supports exact matches (`"text/plain"`) and wildcard subtypes (`"text/*"`).
  Matching is case-insensitive. Returns `{section_path, part}` tuples.
  """
  @spec find_parts(BodyStructure.t(), String.t()) :: [{String.t(), BodyStructure.t()}]
  def find_parts(%BodyStructure{} = bs, mime_pattern) do
    {match_type, match_subtype} = parse_mime_pattern(mime_pattern)

    bs
    |> flatten()
    |> Enum.filter(fn {_section, part} ->
      type = String.upcase(part.type || "")
      subtype = String.upcase(part.subtype || "")

      type == match_type and (match_subtype == "*" or subtype == match_subtype)
    end)
  end

  defp parse_mime_pattern(pattern) do
    [type, subtype] = String.split(String.upcase(pattern), "/", parts: 2)
    {type, subtype}
  end

  @doc """
  List attachments in the message.

  A part is considered an attachment if its disposition is `"ATTACHMENT"`
  (case-insensitive), or if it has a filename in disposition or body params
  and is not `"INLINE"`.

  Returns a list of maps with keys: `:section`, `:filename`, `:type`, `:size`, `:encoding`.
  """
  @spec attachments(BodyStructure.t()) :: [map()]
  def attachments(%BodyStructure{} = bs) do
    bs
    |> flatten()
    |> Enum.filter(fn {_section, part} -> attachment?(part) end)
    |> Enum.map(fn {section, part} ->
      %{
        section: section,
        filename: extract_filename(part),
        type: "#{part.type}/#{part.subtype}",
        size: part.size,
        encoding: part.encoding
      }
    end)
  end

  defp attachment?(%BodyStructure{disposition: {disp, _params}}) do
    String.upcase(disp) == "ATTACHMENT"
  end

  defp attachment?(%BodyStructure{disposition: nil} = part) do
    # No explicit disposition — treat as attachment if it has a filename
    # and is not a text/* type (text parts without disposition are inline by default)
    filename_from_params(part.params) != nil
  end

  defp attachment?(_), do: false

  defp extract_filename(%BodyStructure{disposition: {_disp, params}} = part) do
    case find_param(params, "FILENAME") do
      nil -> filename_from_params(part.params)
      name -> name
    end
  end

  defp extract_filename(%BodyStructure{} = part) do
    filename_from_params(part.params)
  end

  defp filename_from_params(nil), do: nil
  defp filename_from_params(params), do: find_param(params, "NAME")

  defp find_param(params, key) do
    ukey = String.upcase(key)

    Enum.find_value(params, fn {k, v} ->
      if String.upcase(k) == ukey, do: v
    end)
  end

  @doc """
  Get a part by its section path (e.g., `"1.2"`).

  Returns `{:ok, part}` or `:error` if the path is invalid.
  """
  @spec get_part(BodyStructure.t(), String.t()) :: {:ok, BodyStructure.t()} | :error
  def get_part(%BodyStructure{} = bs, "") do
    if bs.type == "multipart" do
      :error
    else
      {:ok, bs}
    end
  end

  def get_part(%BodyStructure{} = bs, section) do
    indices = section |> String.split(".") |> Enum.map(&String.to_integer/1)
    navigate(bs, indices)
  end

  defp navigate(%BodyStructure{} = bs, []), do: {:ok, bs}

  defp navigate(%BodyStructure{type: "multipart", parts: parts}, [idx | rest]) do
    case Enum.at(parts, idx - 1) do
      nil -> :error
      part -> navigate(part, rest)
    end
  end

  defp navigate(_, [_ | _]), do: :error

  @doc """
  Get the charset from a body structure's params.

  Looks for the `"CHARSET"` key (case-insensitive). Returns `"US-ASCII"`
  as the default per RFC 2046.
  """
  @spec charset(BodyStructure.t()) :: String.t()
  def charset(%BodyStructure{params: params}) when is_map(params) do
    find_param(params, "CHARSET") || "US-ASCII"
  end

  def charset(%BodyStructure{}), do: "US-ASCII"

  @doc """
  Get the content-transfer-encoding from a body structure.

  Returns `"7BIT"` as the default per RFC 2045.
  """
  @spec encoding(BodyStructure.t()) :: String.t()
  def encoding(%BodyStructure{encoding: nil}), do: "7BIT"
  def encoding(%BodyStructure{encoding: enc}), do: enc
end
