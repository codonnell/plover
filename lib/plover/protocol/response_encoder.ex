defmodule Plover.Protocol.ResponseEncoder do
  @moduledoc """
  Serializes response structs to IMAP wire-format strings.

  This is the inverse of `Plover.Protocol.Parser` — it takes the same struct
  types that the parser produces and encodes them back to valid IMAP protocol
  strings. Primarily useful for the `Plover.Transport.Mock` higher-level API,
  which lets users build test responses from structs rather than raw wire protocol.

  See the [Testing Guide](testing.md) for usage examples.
  """

  alias Plover.Response.{Tagged, Continuation, BodyStructure, Envelope, Address, ESearch}
  alias Plover.Response.Mailbox
  alias Plover.Response.Message

  @doc """
  Encode a response struct to an IMAP wire-format binary string.
  """
  @spec encode(struct()) :: binary()
  def encode(%Tagged{} = resp) do
    status = status_to_wire(resp.status)
    code_part = encode_resp_code(resp.code)
    "#{resp.tag} #{status}#{code_part} #{resp.text}\r\n"
  end

  def encode(%Mailbox.Exists{count: count}) do
    "* #{count} EXISTS\r\n"
  end

  def encode(%Mailbox.Flags{flags: flags}) do
    flag_str = flags |> Enum.map(&flag_to_wire/1) |> Enum.join(" ")
    "* FLAGS (#{flag_str})\r\n"
  end

  def encode(%Mailbox.List{} = list) do
    flag_str = list.flags |> Enum.map(&flag_to_wire/1) |> Enum.join(" ")
    delimiter = encode_nstring(list.delimiter)
    name = encode_astring(list.name)
    "* LIST (#{flag_str}) #{delimiter} #{name}\r\n"
  end

  def encode(%Mailbox.Status{} = status) do
    atts = encode_status_atts(status)
    "* STATUS #{encode_astring(status.name)} (#{atts})\r\n"
  end

  def encode(%Message.Fetch{} = fetch) do
    atts = encode_fetch_attrs(fetch.attrs)
    "* #{fetch.seq} FETCH (#{atts})\r\n"
  end

  def encode(%Message.Expunge{seq: seq}) do
    "* #{seq} EXPUNGE\r\n"
  end

  def encode(%ESearch{} = es) do
    parts = ["* ESEARCH"]
    parts = if es.tag, do: parts ++ ["(TAG \"#{es.tag}\")"], else: parts
    parts = if es.uid, do: parts ++ ["UID"], else: parts
    parts = if es.min, do: parts ++ ["MIN #{es.min}"], else: parts
    parts = if es.max, do: parts ++ ["MAX #{es.max}"], else: parts
    parts = if es.count, do: parts ++ ["COUNT #{es.count}"], else: parts
    parts = if es.all, do: parts ++ ["ALL #{es.all}"], else: parts
    Enum.join(parts, " ") <> "\r\n"
  end

  def encode(%Continuation{text: text}) do
    text = text || ""

    if text == "" do
      "+\r\n"
    else
      "+ #{text}\r\n"
    end
  end

  @doc """
  Encode an untagged status response (OK/NO/BAD/BYE).
  """
  @spec encode_untagged(atom(), keyword()) :: binary()
  def encode_untagged(status, opts \\ []) do
    code = Keyword.get(opts, :code)
    text = Keyword.get(opts, :text, "")
    status_str = status_to_wire(status)
    code_part = encode_resp_code(code)
    "* #{status_str}#{code_part} #{text}\r\n"
  end

  # --- Response code encoding ---

  defp encode_resp_code(nil), do: ""
  defp encode_resp_code({:alert, nil}), do: " [ALERT]"
  defp encode_resp_code({:parse, nil}), do: " [PARSE]"
  defp encode_resp_code({:read_only, nil}), do: " [READ-ONLY]"
  defp encode_resp_code({:read_write, nil}), do: " [READ-WRITE]"
  defp encode_resp_code({:try_create, nil}), do: " [TRYCREATE]"
  defp encode_resp_code({:uid_not_sticky, nil}), do: " [UIDNOTSTICKY]"
  defp encode_resp_code({:closed, nil}), do: " [CLOSED]"
  defp encode_resp_code({:authentication_failed, nil}), do: " [AUTHENTICATIONFAILED]"
  defp encode_resp_code({:authorization_failed, nil}), do: " [AUTHORIZATIONFAILED]"
  defp encode_resp_code({:expired, nil}), do: " [EXPIRED]"
  defp encode_resp_code({:privacy_required, nil}), do: " [PRIVACYREQUIRED]"
  defp encode_resp_code({:contact_admin, nil}), do: " [CONTACTADMIN]"
  defp encode_resp_code({:no_perm, nil}), do: " [NOPERM]"
  defp encode_resp_code({:in_use, nil}), do: " [INUSE]"
  defp encode_resp_code({:expunge_issued, nil}), do: " [EXPUNGEISSUED]"
  defp encode_resp_code({:over_quota, nil}), do: " [OVERQUOTA]"
  defp encode_resp_code({:already_exists, nil}), do: " [ALREADYEXISTS]"
  defp encode_resp_code({:nonexistent, nil}), do: " [NONEXISTENT]"
  defp encode_resp_code({:unavailable, nil}), do: " [UNAVAILABLE]"
  defp encode_resp_code({:server_bug, nil}), do: " [SERVERBUG]"
  defp encode_resp_code({:client_bug, nil}), do: " [CLIENTBUG]"
  defp encode_resp_code({:cannot, nil}), do: " [CANNOT]"
  defp encode_resp_code({:limit, nil}), do: " [LIMIT]"
  defp encode_resp_code({:corruption, nil}), do: " [CORRUPTION]"
  defp encode_resp_code({:has_children, nil}), do: " [HASCHILDREN]"
  defp encode_resp_code({:not_saved, nil}), do: " [NOTSAVED]"
  defp encode_resp_code({:unknown_cte, nil}), do: " [UNKNOWN-CTE]"

  defp encode_resp_code({:capability, caps}) do
    " [CAPABILITY #{Enum.join(caps, " ")}]"
  end

  defp encode_resp_code({:permanent_flags, flags}) do
    flag_str = flags |> Enum.map(&flag_to_wire/1) |> Enum.join(" ")
    " [PERMANENTFLAGS (#{flag_str})]"
  end

  defp encode_resp_code({:uid_validity, n}), do: " [UIDVALIDITY #{n}]"
  defp encode_resp_code({:uid_next, n}), do: " [UIDNEXT #{n}]"

  defp encode_resp_code({:append_uid, {uid_validity, uid}}) do
    " [APPENDUID #{uid_validity} #{uid}]"
  end

  defp encode_resp_code({:copy_uid, {uid_validity, source, dest}}) do
    " [COPYUID #{uid_validity} #{source} #{dest}]"
  end

  # --- Status encoding ---

  defp status_to_wire(:ok), do: "OK"
  defp status_to_wire(:no), do: "NO"
  defp status_to_wire(:bad), do: "BAD"
  defp status_to_wire(:bye), do: "BYE"

  # --- Flag encoding (inverse of normalize_flag) ---

  defp flag_to_wire(:answered), do: "\\Answered"
  defp flag_to_wire(:flagged), do: "\\Flagged"
  defp flag_to_wire(:deleted), do: "\\Deleted"
  defp flag_to_wire(:seen), do: "\\Seen"
  defp flag_to_wire(:draft), do: "\\Draft"
  defp flag_to_wire(:recent), do: "\\Recent"
  defp flag_to_wire(:wildcard), do: "\\*"
  # Mailbox list flags
  defp flag_to_wire(:noinferiors), do: "\\Noinferiors"
  defp flag_to_wire(:noselect), do: "\\Noselect"
  defp flag_to_wire(:marked), do: "\\Marked"
  defp flag_to_wire(:unmarked), do: "\\Unmarked"
  defp flag_to_wire(:has_children), do: "\\HasChildren"
  defp flag_to_wire(:has_no_children), do: "\\HasNoChildren"
  defp flag_to_wire(:nonexistent), do: "\\NonExistent"
  defp flag_to_wire(:subscribed), do: "\\Subscribed"
  defp flag_to_wire(:remote), do: "\\Remote"
  defp flag_to_wire(:drafts), do: "\\Drafts"
  defp flag_to_wire(:all), do: "\\All"
  defp flag_to_wire(:archive), do: "\\Archive"
  defp flag_to_wire(:junk), do: "\\Junk"
  defp flag_to_wire(:sent), do: "\\Sent"
  defp flag_to_wire(:trash), do: "\\Trash"
  # Non-system flags (keyword flags without backslash)
  defp flag_to_wire(flag) when is_atom(flag), do: Atom.to_string(flag)

  # --- Fetch attribute encoding ---

  defp encode_fetch_attrs(attrs) do
    parts = []

    parts = if Map.has_key?(attrs, :flags) do
      flag_str = attrs.flags |> Enum.map(&flag_to_wire/1) |> Enum.join(" ")
      parts ++ ["FLAGS (#{flag_str})"]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :uid) do
      parts ++ ["UID #{attrs.uid}"]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :internal_date) do
      parts ++ ["INTERNALDATE \"#{attrs.internal_date}\""]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :rfc822_size) do
      parts ++ ["RFC822.SIZE #{attrs.rfc822_size}"]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :envelope) do
      parts ++ ["ENVELOPE #{encode_envelope(attrs.envelope)}"]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :body_structure) do
      parts ++ ["BODYSTRUCTURE #{encode_body_structure(attrs.body_structure)}"]
    else
      parts
    end

    parts = if Map.has_key?(attrs, :body) do
      body_parts =
        Enum.map(attrs.body, fn {section, data} ->
          size = byte_size(data)
          "BODY[#{section}] {#{size}}\r\n#{data}"
        end)

      parts ++ body_parts
    else
      parts
    end

    Enum.join(parts, " ")
  end

  # --- Envelope encoding ---

  defp encode_envelope(%Envelope{} = env) do
    parts = [
      encode_nstring(env.date),
      encode_nstring(env.subject),
      encode_address_list(env.from),
      encode_address_list(env.sender),
      encode_address_list(env.reply_to),
      encode_address_list(env.to),
      encode_address_list(env.cc),
      encode_address_list(env.bcc),
      encode_nstring(env.in_reply_to),
      encode_nstring(env.message_id)
    ]

    "(#{Enum.join(parts, " ")})"
  end

  defp encode_address_list(nil), do: "NIL"
  defp encode_address_list([]), do: "NIL"

  defp encode_address_list(addrs) do
    inner = Enum.map(addrs, &encode_address/1) |> Enum.join(" ")
    "(#{inner})"
  end

  defp encode_address(%Address{} = addr) do
    parts = [
      encode_nstring(addr.name),
      encode_nstring(addr.adl),
      encode_nstring(addr.mailbox),
      encode_nstring(addr.host)
    ]

    "(#{Enum.join(parts, " ")})"
  end

  # --- Body structure encoding ---

  defp encode_body_structure(%BodyStructure{type: "multipart"} = bs) do
    parts = Enum.map(bs.parts, &encode_body_structure/1) |> Enum.join("")
    "(#{parts} \"#{bs.subtype}\")"
  end

  defp encode_body_structure(%BodyStructure{} = bs) do
    parts = [
      encode_nstring(bs.type),
      encode_nstring(bs.subtype),
      encode_body_fld_param(bs.params),
      encode_nstring(bs.id),
      encode_nstring(bs.description),
      encode_nstring(bs.encoding),
      Integer.to_string(bs.size || 0)
    ]

    # For TEXT types, add lines count
    parts =
      if bs.type && String.upcase(bs.type) == "TEXT" do
        parts ++ [Integer.to_string(bs.lines || 0)]
      else
        parts
      end

    "(#{Enum.join(parts, " ")})"
  end

  defp encode_body_fld_param(nil), do: "NIL"
  defp encode_body_fld_param(params) when map_size(params) == 0, do: "NIL"

  defp encode_body_fld_param(params) do
    inner =
      Enum.map(params, fn {k, v} -> "\"#{k}\" \"#{v}\"" end)
      |> Enum.join(" ")

    "(#{inner})"
  end

  # --- Status attribute encoding ---

  defp encode_status_atts(%Mailbox.Status{} = s) do
    parts = []
    parts = if s.messages, do: parts ++ ["MESSAGES #{s.messages}"], else: parts
    parts = if s.recent, do: parts ++ ["RECENT #{s.recent}"], else: parts
    parts = if s.unseen, do: parts ++ ["UNSEEN #{s.unseen}"], else: parts
    parts = if s.uid_next, do: parts ++ ["UIDNEXT #{s.uid_next}"], else: parts
    parts = if s.uid_validity, do: parts ++ ["UIDVALIDITY #{s.uid_validity}"], else: parts
    Enum.join(parts, " ")
  end

  # --- String encoding helpers ---

  defp encode_nstring(nil), do: "NIL"

  defp encode_nstring(str) when is_binary(str) do
    escaped = str |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp encode_astring(str) when is_binary(str) do
    if atom_safe?(str) do
      str
    else
      encode_nstring(str)
    end
  end

  defp atom_safe?(str) do
    str != "" and
      str
      |> String.to_charlist()
      |> Enum.all?(fn c ->
        c > 0x20 and c < 0x7F and c not in [?(, ?), ?{, ?", ?\\]
      end)
  end
end
