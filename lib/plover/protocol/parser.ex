defmodule Plover.Protocol.Parser do
  @moduledoc """
  Recursive-descent parser for IMAP response token lists.

  Consumes token lists produced by `Plover.Protocol.Tokenizer` and
  returns structured response data.

  RFC 9051 Section 7 - Server Responses
  """

  alias Plover.Content
  alias Plover.Response.{Tagged, Continuation, Envelope, Address, BodyStructure, ESearch}
  alias Plover.Response.Mailbox
  alias Plover.Response.Message

  @type token :: term()
  @type tokens :: [token()]

  @doc """
  Parse a token list into a response struct.
  """
  @spec parse(tokens()) :: {:ok, term()} | {:error, term()}
  def parse([:star | rest]) do
    parse_untagged(rest)
  end

  def parse([:plus | rest]) do
    parse_continuation(rest)
  end

  def parse([{:atom, tag} | rest]) do
    parse_tagged(tag, rest)
  end

  def parse(tokens) do
    {:error, {:unexpected_tokens, tokens}}
  end

  # --- Tagged responses ---
  # RFC 9051: response-tagged = tag SP resp-cond-state CRLF
  # resp-cond-state = ("OK" / "NO" / "BAD") SP resp-text

  defp parse_tagged(tag, [{:atom, status_str} | rest]) do
    case parse_status(status_str) do
      {:ok, status} ->
        {code, text} = parse_resp_text(rest)
        {:ok, %Tagged{tag: tag, status: status, code: code, text: text}}

      :error ->
        {:error, {:invalid_status, status_str}}
    end
  end

  defp parse_tagged(_tag, tokens), do: {:error, {:invalid_tagged, tokens}}

  defp parse_status(s) when s in ~w(OK ok Ok), do: {:ok, :ok}
  defp parse_status(s) when s in ~w(NO no No), do: {:ok, :no}
  defp parse_status(s) when s in ~w(BAD bad Bad), do: {:ok, :bad}
  defp parse_status(_), do: :error

  # --- Continuation responses ---
  # RFC 9051: continue-req = "+" SP (resp-text / base64) CRLF

  defp parse_continuation([:crlf]) do
    {:ok, %Continuation{text: ""}}
  end

  defp parse_continuation(tokens) do
    text = tokens_to_text(tokens)

    # Check if it's a base64 challenge (single token, valid base64 chars)
    case tokens do
      [{:atom, maybe_b64}, :crlf] ->
        if base64?(maybe_b64) do
          {:ok, %Continuation{text: "", base64: maybe_b64}}
        else
          {:ok, %Continuation{text: text}}
        end

      _ ->
        {:ok, %Continuation{text: text}}
    end
  end

  defp base64?(str) do
    Regex.match?(~r/^[A-Za-z0-9+\/]+=*$/, str) and byte_size(str) > 0
  end

  # --- Untagged responses ---
  # RFC 9051: response-data = "*" SP (resp-cond-state / resp-cond-bye /
  #           mailbox-data / message-data / capability-data / enable-data) CRLF

  defp parse_untagged([{:number, n}, {:atom, "EXISTS"} | _rest]) do
    {:ok, %Mailbox.Exists{count: n}}
  end

  defp parse_untagged([{:number, n}, {:atom, "EXPUNGE"} | _rest]) do
    {:ok, %Message.Expunge{seq: n}}
  end

  defp parse_untagged([{:number, n}, {:atom, "FETCH"}, :lparen | rest]) do
    parse_fetch(n, rest)
  end

  defp parse_untagged([{:atom, "CAPABILITY"} | rest]) do
    caps = collect_atoms(rest)
    {:ok, {:capability, caps}}
  end

  defp parse_untagged([{:atom, "FLAGS"}, :lparen | rest]) do
    {flags, _rest} = parse_flag_list(rest)
    {:ok, %Mailbox.Flags{flags: flags}}
  end

  defp parse_untagged([{:atom, "LIST"}, :lparen | rest]) do
    parse_list_response(rest)
  end

  defp parse_untagged([{:atom, "STATUS"} | rest]) do
    parse_status_response(rest)
  end

  defp parse_untagged([{:atom, "ESEARCH"} | rest]) do
    parse_esearch(rest)
  end

  defp parse_untagged([{:atom, "BYE"} | rest]) do
    text = tokens_to_text(rest)
    {:ok, {:bye, text}}
  end

  defp parse_untagged([{:atom, "OK"} | rest]) do
    {code, text} = parse_resp_text(rest)
    {:ok, {:ok, code, text}}
  end

  defp parse_untagged([{:atom, "NO"} | rest]) do
    {code, text} = parse_resp_text(rest)
    {:ok, {:no, code, text}}
  end

  defp parse_untagged([{:atom, "BAD"} | rest]) do
    {code, text} = parse_resp_text(rest)
    {:ok, {:bad, code, text}}
  end

  defp parse_untagged([{:atom, "PREAUTH"} | rest]) do
    {code, text} = parse_resp_text(rest)
    {:ok, {:preauth, code, text}}
  end

  defp parse_untagged([{:atom, "ENABLED"} | rest]) do
    caps = collect_atoms(rest)
    {:ok, {:enabled, caps}}
  end

  defp parse_untagged(tokens) do
    {:error, {:unrecognized_untagged, tokens}}
  end

  # --- resp-text parsing ---
  # RFC 9051: resp-text = ["[" resp-text-code "]" SP] [text]

  defp parse_resp_text([:lbracket | rest]) do
    {code, after_bracket} = parse_resp_text_code(rest)
    text = tokens_to_text(after_bracket)
    {code, text}
  end

  defp parse_resp_text(tokens) do
    {nil, tokens_to_text(tokens)}
  end

  # --- resp-text-code parsing ---
  # RFC 9051 Section 7.1

  defp parse_resp_text_code([{:atom, "ALERT"}, :rbracket | rest]) do
    {{:alert, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CAPABILITY"} | rest]) do
    {caps, remaining} = collect_until_rbracket(rest)
    {{:capability, caps}, remaining}
  end

  defp parse_resp_text_code([{:atom, "PARSE"}, :rbracket | rest]) do
    {{:parse, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "PERMANENTFLAGS"}, :lparen | rest]) do
    {flags, after_flags} = parse_flag_list(rest)
    # Consume the closing bracket
    remaining = drop_until_after_rbracket(after_flags)
    {{:permanent_flags, flags}, remaining}
  end

  defp parse_resp_text_code([{:atom, "READ-ONLY"}, :rbracket | rest]) do
    {{:read_only, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "READ-WRITE"}, :rbracket | rest]) do
    {{:read_write, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "TRYCREATE"}, :rbracket | rest]) do
    {{:try_create, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "UIDNEXT"}, {:number, n}, :rbracket | rest]) do
    {{:uid_next, n}, rest}
  end

  defp parse_resp_text_code([{:atom, "UIDVALIDITY"}, {:number, n}, :rbracket | rest]) do
    {{:uid_validity, n}, rest}
  end

  defp parse_resp_text_code([
         {:atom, "APPENDUID"},
         {:number, uid_validity},
         {:number, uid},
         :rbracket | rest
       ]) do
    {{:append_uid, {uid_validity, uid}}, rest}
  end

  defp parse_resp_text_code([{:atom, "COPYUID"}, {:number, uid_validity} | rest]) do
    {source_tokens, remaining} = collect_uid_set_tokens(rest)
    {dest_tokens, remaining} = collect_uid_set_tokens(remaining)
    source_set = uid_set_tokens_to_string(source_tokens)
    dest_set = uid_set_tokens_to_string(dest_tokens)

    remaining =
      case remaining do
        [:rbracket | r] -> r
        r -> r
      end

    {{:copy_uid, {uid_validity, source_set, dest_set}}, remaining}
  end

  defp parse_resp_text_code([{:atom, "UIDNOTSTICKY"}, :rbracket | rest]) do
    {{:uid_not_sticky, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CLOSED"}, :rbracket | rest]) do
    {{:closed, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "AUTHENTICATIONFAILED"}, :rbracket | rest]) do
    {{:authentication_failed, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "AUTHORIZATIONFAILED"}, :rbracket | rest]) do
    {{:authorization_failed, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "EXPIRED"}, :rbracket | rest]) do
    {{:expired, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "PRIVACYREQUIRED"}, :rbracket | rest]) do
    {{:privacy_required, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CONTACTADMIN"}, :rbracket | rest]) do
    {{:contact_admin, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "NOPERM"}, :rbracket | rest]) do
    {{:no_perm, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "INUSE"}, :rbracket | rest]) do
    {{:in_use, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "EXPUNGEISSUED"}, :rbracket | rest]) do
    {{:expunge_issued, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "OVERQUOTA"}, :rbracket | rest]) do
    {{:over_quota, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "ALREADYEXISTS"}, :rbracket | rest]) do
    {{:already_exists, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "NONEXISTENT"}, :rbracket | rest]) do
    {{:nonexistent, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "UNAVAILABLE"}, :rbracket | rest]) do
    {{:unavailable, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "SERVERBUG"}, :rbracket | rest]) do
    {{:server_bug, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CLIENTBUG"}, :rbracket | rest]) do
    {{:client_bug, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CANNOT"}, :rbracket | rest]) do
    {{:cannot, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "LIMIT"}, :rbracket | rest]) do
    {{:limit, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "CORRUPTION"}, :rbracket | rest]) do
    {{:corruption, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "HASCHILDREN"}, :rbracket | rest]) do
    {{:has_children, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "NOTSAVED"}, :rbracket | rest]) do
    {{:not_saved, nil}, rest}
  end

  defp parse_resp_text_code([{:atom, "UNKNOWN-CTE"}, :rbracket | rest]) do
    {{:unknown_cte, nil}, rest}
  end

  # Generic: atom [SP text-until-rbracket]
  defp parse_resp_text_code([{:atom, code} | rest]) do
    {data, remaining} = collect_until_rbracket(rest)
    value = if data == [], do: nil, else: Enum.join(data, " ")
    {{String.downcase(code) |> String.replace("-", "_") |> String.to_atom(), value}, remaining}
  end

  defp parse_resp_text_code(tokens) do
    {nil, tokens}
  end

  # --- LIST response ---
  # RFC 9051: mailbox-list = "(" [mbx-list-flags] ")" SP
  #           (DQUOTE QUOTED-CHAR DQUOTE / nil) SP mailbox

  defp parse_list_response(tokens) do
    {flags, rest} = parse_flag_list(tokens)

    {delimiter, rest} =
      case rest do
        [nil | r] -> {nil, r}
        [{:quoted_string, d} | r] -> {d, r}
        [{:atom, d} | r] -> {d, r}
      end

    name =
      case rest do
        [{:quoted_string, n} | _] -> n
        [{:atom, n} | _] -> n
        [{:literal, n} | _] -> n
      end

    list_flags = Enum.map(flags, &normalize_list_flag/1)
    {:ok, %Mailbox.List{flags: list_flags, delimiter: delimiter, name: name}}
  end

  defp normalize_list_flag(flag) when is_atom(flag), do: flag

  # --- STATUS response ---
  # RFC 9051: "STATUS" SP mailbox SP "(" [status-att-list] ")"

  defp parse_status_response([{:quoted_string, name}, :lparen | rest]) do
    parse_status_atts(rest, %Mailbox.Status{name: name})
  end

  defp parse_status_response([{:atom, name}, :lparen | rest]) do
    parse_status_atts(rest, %Mailbox.Status{name: name})
  end

  defp parse_status_atts([:rparen | _], %Mailbox.Status{} = acc), do: {:ok, acc}

  defp parse_status_atts([{:atom, "MESSAGES"}, {:number, n} | rest], %Mailbox.Status{} = acc) do
    parse_status_atts(rest, %{acc | messages: n})
  end

  defp parse_status_atts([{:atom, "RECENT"}, {:number, n} | rest], %Mailbox.Status{} = acc) do
    parse_status_atts(rest, %{acc | recent: n})
  end

  defp parse_status_atts([{:atom, "UNSEEN"}, {:number, n} | rest], %Mailbox.Status{} = acc) do
    parse_status_atts(rest, %{acc | unseen: n})
  end

  defp parse_status_atts([{:atom, "UIDNEXT"}, {:number, n} | rest], %Mailbox.Status{} = acc) do
    parse_status_atts(rest, %{acc | uid_next: n})
  end

  defp parse_status_atts([{:atom, "UIDVALIDITY"}, {:number, n} | rest], %Mailbox.Status{} = acc) do
    parse_status_atts(rest, %{acc | uid_validity: n})
  end

  defp parse_status_atts([_ | rest], %Mailbox.Status{} = acc), do: parse_status_atts(rest, acc)

  # --- ESEARCH response ---
  # RFC 9051: esearch-response = "ESEARCH" [search-correlator] [SP "UID"]
  #           *(SP search-return-data)

  defp parse_esearch(tokens) do
    {tag, rest} = parse_search_correlator(tokens)
    {uid, rest} = parse_uid_flag(rest)
    esearch = parse_esearch_data(rest, %ESearch{tag: tag, uid: uid})
    {:ok, esearch}
  end

  defp parse_search_correlator([:lparen, {:atom, "TAG"}, {:quoted_string, tag}, :rparen | rest]) do
    {tag, rest}
  end

  defp parse_search_correlator(tokens), do: {nil, tokens}

  defp parse_uid_flag([{:atom, "UID"} | rest]), do: {true, rest}
  defp parse_uid_flag(tokens), do: {false, tokens}

  defp parse_esearch_data([:crlf], %ESearch{} = acc), do: acc
  defp parse_esearch_data([], %ESearch{} = acc), do: acc

  defp parse_esearch_data([{:atom, "MIN"}, {:number, n} | rest], %ESearch{} = acc) do
    parse_esearch_data(rest, %{acc | min: n})
  end

  defp parse_esearch_data([{:atom, "MAX"}, {:number, n} | rest], %ESearch{} = acc) do
    parse_esearch_data(rest, %{acc | max: n})
  end

  defp parse_esearch_data([{:atom, "COUNT"}, {:number, n} | rest], %ESearch{} = acc) do
    parse_esearch_data(rest, %{acc | count: n})
  end

  defp parse_esearch_data([{:atom, "ALL"} | rest], %ESearch{} = acc) do
    {set_tokens, rest} = collect_uid_set_tokens(rest)
    set = uid_set_tokens_to_string(set_tokens)
    parse_esearch_data(rest, %{acc | all: set})
  end

  defp parse_esearch_data([_ | rest], %ESearch{} = acc), do: parse_esearch_data(rest, acc)

  # --- FETCH response ---
  # RFC 9051: msg-att = "(" (msg-att-dynamic / msg-att-static)
  #           *(SP (msg-att-dynamic / msg-att-static)) ")"

  defp parse_fetch(seq, tokens) do
    {attrs, _rest} = parse_msg_atts(tokens, %{})
    {:ok, %Message.Fetch{seq: seq, attrs: attrs}}
  end

  defp parse_msg_atts([:rparen | rest], acc), do: {acc, rest}
  defp parse_msg_atts([:crlf], acc), do: {acc, []}
  defp parse_msg_atts([], acc), do: {acc, []}

  defp parse_msg_atts([{:atom, "FLAGS"}, :lparen | rest], acc) do
    {flags, rest} = parse_fetch_flags(rest, [])
    parse_msg_atts(rest, Map.put(acc, :flags, flags))
  end

  defp parse_msg_atts([{:atom, "UID"}, {:number, uid} | rest], acc) do
    parse_msg_atts(rest, Map.put(acc, :uid, uid))
  end

  defp parse_msg_atts([{:atom, "INTERNALDATE"}, {:quoted_string, date} | rest], acc) do
    parse_msg_atts(rest, Map.put(acc, :internal_date, date))
  end

  defp parse_msg_atts([{:atom, "RFC822.SIZE"}, {:number, size} | rest], acc) do
    parse_msg_atts(rest, Map.put(acc, :rfc822_size, size))
  end

  defp parse_msg_atts([{:atom, "ENVELOPE"}, :lparen | rest], acc) do
    {envelope, rest} = parse_envelope(rest)
    parse_msg_atts(rest, Map.put(acc, :envelope, envelope))
  end

  defp parse_msg_atts([{:atom, "BODYSTRUCTURE"}, :lparen | rest], acc) do
    {body_structure, rest} = parse_body_structure(rest)
    parse_msg_atts(rest, Map.put(acc, :body_structure, body_structure))
  end

  defp parse_msg_atts([{:atom, "BODY"}, :lbracket | rest], acc) do
    {section, rest} = parse_section(rest)
    {partial, rest} = parse_partial(rest)
    {data, rest} = parse_nstring(rest)
    key = section_key(section, partial)
    body = Map.get(acc, :body, %{})
    parse_msg_atts(rest, Map.put(acc, :body, Map.put(body, key, data)))
  end

  # BODY without [] is BODYSTRUCTURE in non-extensible form
  defp parse_msg_atts([{:atom, "BODY"}, :lparen | rest], acc) do
    {body_structure, rest} = parse_body_structure(rest)
    parse_msg_atts(rest, Map.put(acc, :body_structure, body_structure))
  end

  defp parse_msg_atts([_ | rest], acc), do: parse_msg_atts(rest, acc)

  # --- Flag parsing ---

  defp parse_fetch_flags([:rparen | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_fetch_flags([{:flag, flag_str} | rest], acc) do
    parse_fetch_flags(rest, [normalize_flag(flag_str) | acc])
  end

  defp parse_fetch_flags([{:atom, flag_str} | rest], acc) do
    parse_fetch_flags(rest, [String.to_atom(flag_str) | acc])
  end

  defp parse_fetch_flags([_ | rest], acc), do: parse_fetch_flags(rest, acc)

  defp parse_flag_list(tokens), do: parse_flag_list_inner(tokens, [])

  defp parse_flag_list_inner([:rparen | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_flag_list_inner([{:flag, flag_str} | rest], acc) do
    parse_flag_list_inner(rest, [normalize_flag(flag_str) | acc])
  end

  defp parse_flag_list_inner([{:atom, flag_str} | rest], acc) do
    parse_flag_list_inner(rest, [String.to_atom(flag_str) | acc])
  end

  defp parse_flag_list_inner([_ | rest], acc), do: parse_flag_list_inner(rest, acc)
  defp parse_flag_list_inner([], acc), do: {Enum.reverse(acc), []}

  defp normalize_flag("\\Answered"), do: :answered
  defp normalize_flag("\\Flagged"), do: :flagged
  defp normalize_flag("\\Deleted"), do: :deleted
  defp normalize_flag("\\Seen"), do: :seen
  defp normalize_flag("\\Draft"), do: :draft
  defp normalize_flag("\\Recent"), do: :recent
  defp normalize_flag("\\*"), do: :wildcard
  # Mailbox list flags
  defp normalize_flag("\\Noinferiors"), do: :noinferiors
  defp normalize_flag("\\Noselect"), do: :noselect
  defp normalize_flag("\\Marked"), do: :marked
  defp normalize_flag("\\Unmarked"), do: :unmarked
  defp normalize_flag("\\HasChildren"), do: :has_children
  defp normalize_flag("\\HasNoChildren"), do: :has_no_children
  defp normalize_flag("\\NonExistent"), do: :nonexistent
  defp normalize_flag("\\Subscribed"), do: :subscribed
  defp normalize_flag("\\Remote"), do: :remote
  defp normalize_flag("\\Drafts"), do: :drafts
  defp normalize_flag("\\All"), do: :all
  defp normalize_flag("\\Archive"), do: :archive
  defp normalize_flag("\\Flagged" <> _), do: :flagged
  defp normalize_flag("\\Junk"), do: :junk
  defp normalize_flag("\\Sent"), do: :sent
  defp normalize_flag("\\Trash"), do: :trash
  defp normalize_flag("\\" <> name), do: String.downcase(name) |> String.to_atom()

  # --- Envelope parsing ---
  # RFC 9051: envelope = "(" env-date SP env-subject SP env-from SP
  #           env-sender SP env-reply-to SP env-to SP env-cc SP
  #           env-bcc SP env-in-reply-to SP env-message-id ")"

  defp parse_envelope(tokens) do
    {date, rest} = parse_nstring(tokens)
    {subject, rest} = parse_nstring(rest)
    {from, rest} = parse_address_list(rest)
    {sender, rest} = parse_address_list(rest)
    {reply_to, rest} = parse_address_list(rest)
    {to, rest} = parse_address_list(rest)
    {cc, rest} = parse_address_list(rest)
    {bcc, rest} = parse_address_list(rest)
    {in_reply_to, rest} = parse_nstring(rest)
    {message_id, rest} = parse_nstring(rest)
    rest = skip_rparen(rest)

    {:ok, subject} = Content.decode_encoded_words(subject)

    envelope = %Envelope{
      date: date,
      subject: subject,
      from: from || [],
      sender: sender || [],
      reply_to: reply_to || [],
      to: to || [],
      cc: cc || [],
      bcc: bcc || [],
      in_reply_to: in_reply_to,
      message_id: message_id
    }

    {envelope, rest}
  end

  # --- Address parsing ---
  # RFC 9051: address = "(" addr-name SP addr-adl SP addr-mailbox SP addr-host ")"

  defp parse_address_list([nil | rest]), do: {nil, rest}

  defp parse_address_list([:lparen | rest]) do
    parse_addresses(rest, [])
  end

  defp parse_addresses([:rparen | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_addresses([:lparen | rest], acc) do
    {name, rest} = parse_nstring(rest)
    {adl, rest} = parse_nstring(rest)
    {mailbox, rest} = parse_nstring(rest)
    {host, rest} = parse_nstring(rest)
    rest = skip_rparen(rest)
    {:ok, name} = Content.decode_encoded_words(name)
    addr = %Address{name: name, adl: adl, mailbox: mailbox, host: host}
    parse_addresses(rest, [addr | acc])
  end

  # --- Body Structure parsing ---
  # RFC 9051: body = "(" (body-type-1part / body-type-mpart) ")"

  defp parse_body_structure([:lparen | rest]) do
    # This starts with another "(", so it's multipart
    parse_multipart_body([:lparen | rest], [])
  end

  defp parse_body_structure([{:quoted_string, type} | rest]) do
    parse_single_part_body(type, rest)
  end

  defp parse_body_structure([{:atom, type} | rest]) do
    parse_single_part_body(type, rest)
  end

  # Multipart: 1*body SP media-subtype [SP body-ext-mpart]
  defp parse_multipart_body([:lparen | rest], parts) do
    {part, rest} = parse_body_structure(rest)
    parse_multipart_body(rest, [part | parts])
  end

  defp parse_multipart_body([{:quoted_string, subtype} | rest], parts) do
    # Skip extension data until closing paren
    rest = skip_body_extensions(rest)
    bs = %BodyStructure{type: "multipart", subtype: subtype, parts: Enum.reverse(parts)}
    {bs, rest}
  end

  defp parse_multipart_body([{:atom, subtype} | rest], parts) do
    rest = skip_body_extensions(rest)
    bs = %BodyStructure{type: "multipart", subtype: subtype, parts: Enum.reverse(parts)}
    {bs, rest}
  end

  # Single part: media-type SP body-fields [SP body-ext-1part]
  # body-fields = body-fld-param SP body-fld-id SP body-fld-desc SP
  #               body-fld-enc SP body-fld-octets
  defp parse_single_part_body(type, rest) do
    {subtype, rest} = parse_string_value(rest)
    {params, rest} = parse_body_fld_param(rest)
    {id, rest} = parse_nstring(rest)
    {description, rest} = parse_nstring(rest)
    {encoding, rest} = parse_string_value(rest)
    {size, rest} = parse_number(rest)

    bs = %BodyStructure{
      type: type,
      subtype: subtype,
      params: params,
      id: id,
      description: description,
      encoding: encoding,
      size: size
    }

    # For TEXT types, lines follows
    bs =
      if String.upcase(type) == "TEXT" do
        {lines, rest} = parse_number(rest)
        {%{bs | lines: lines}, rest}
      else
        {bs, rest}
      end

    {%BodyStructure{} = bs, rest} = bs
    # Skip extension data until closing paren
    rest = skip_body_extensions(rest)
    {bs, rest}
  end

  # body-fld-param = "(" string SP string *(SP string SP string) ")" / nil
  defp parse_body_fld_param([nil | rest]), do: {%{}, rest}

  defp parse_body_fld_param([:lparen | rest]) do
    parse_body_params(rest, %{})
  end

  defp parse_body_fld_param(rest), do: {%{}, rest}

  defp parse_body_params([:rparen | rest], acc), do: {acc, rest}

  defp parse_body_params(tokens, acc) do
    {key, rest} = parse_string_value(tokens)
    {value, rest} = parse_string_value(rest)
    parse_body_params(rest, Map.put(acc, key, value))
  end

  # --- Section parsing ---
  # RFC 9051: section = "[" [section-spec] "]"

  defp parse_section(rest) do
    {parts, rest} = collect_section_parts(rest, [])
    {Enum.join(parts), rest}
  end

  defp collect_section_parts([:rbracket | rest], acc) do
    {Enum.reverse(acc), rest}
  end

  defp collect_section_parts([{:atom, s} | rest], acc) do
    collect_section_parts(rest, [s | acc])
  end

  defp collect_section_parts([{:number, n} | rest], acc) do
    collect_section_parts(rest, [Integer.to_string(n) | acc])
  end

  defp collect_section_parts([:lparen | rest], acc) do
    {inner, rest} = collect_paren_contents(rest, [])
    collect_section_parts(rest, [inner | acc])
  end

  defp collect_section_parts([_ | rest], acc), do: collect_section_parts(rest, acc)

  defp collect_paren_contents([:rparen | rest], acc) do
    {Enum.reverse(acc) |> Enum.join(" "), rest}
  end

  defp collect_paren_contents([{:atom, s} | rest], acc),
    do: collect_paren_contents(rest, [s | acc])

  defp collect_paren_contents([{:quoted_string, s} | rest], acc),
    do: collect_paren_contents(rest, [s | acc])

  defp collect_paren_contents([_ | rest], acc), do: collect_paren_contents(rest, acc)

  # Partial: "<" number ">"
  defp parse_partial([{:atom, partial} | rest]) do
    if String.starts_with?(partial, "<") and String.ends_with?(partial, ">") do
      {partial, rest}
    else
      {nil, [{:atom, partial} | rest]}
    end
  end

  defp parse_partial(rest), do: {nil, rest}

  defp section_key(section, nil), do: section
  defp section_key(section, partial), do: section <> partial

  # --- Utility functions ---

  defp parse_nstring([nil | rest]), do: {nil, rest}
  defp parse_nstring([{:quoted_string, s} | rest]), do: {s, rest}
  defp parse_nstring([{:literal, s} | rest]), do: {s, rest}
  defp parse_nstring([{:atom, "NIL"} | rest]), do: {nil, rest}
  defp parse_nstring(rest), do: {nil, rest}

  defp parse_string_value([{:quoted_string, s} | rest]), do: {s, rest}
  defp parse_string_value([{:literal, s} | rest]), do: {s, rest}
  defp parse_string_value([{:atom, s} | rest]), do: {s, rest}
  defp parse_string_value([nil | rest]), do: {nil, rest}
  defp parse_string_value(rest), do: {nil, rest}

  defp parse_number([{:number, n} | rest]), do: {n, rest}
  defp parse_number(rest), do: {nil, rest}

  defp skip_rparen([:rparen | rest]), do: rest
  defp skip_rparen(rest), do: rest

  defp skip_body_extensions([:rparen | rest]), do: rest
  defp skip_body_extensions([:crlf | _] = rest), do: rest
  defp skip_body_extensions([]), do: []

  defp skip_body_extensions([:lparen | rest]) do
    rest = skip_nested_parens(rest, 1)
    skip_body_extensions(rest)
  end

  defp skip_body_extensions([_ | rest]), do: skip_body_extensions(rest)

  defp skip_nested_parens(rest, 0), do: rest
  defp skip_nested_parens([:lparen | rest], depth), do: skip_nested_parens(rest, depth + 1)
  defp skip_nested_parens([:rparen | rest], depth), do: skip_nested_parens(rest, depth - 1)
  defp skip_nested_parens([_ | rest], depth), do: skip_nested_parens(rest, depth)

  # Collect tokens that form a uid-set (numbers, commas, colons as atoms)
  # uid-set = (uniqueid / uid-range) *("," uid-set)
  #
  # After tokenization, a uid-set like "304,319:320" appears as:
  # {:number, 304}, {:atom, ",319:320"}
  # because "304" is consumed as a number, then ",319:320" starts with "," which is ATOM-CHAR.
  #
  # A uid-set ends when we see a token that can't be part of it:
  # - a {:number, _} that comes after a complete number (not after , or :)
  # - any non-uid-set token
  # State: :start = expecting first token, :need_continuation = last token ended with
  # a digit (complete element), :need_more = last token ended with , or : (expecting more)
  defp collect_uid_set_tokens(tokens), do: collect_uid_set_tokens(tokens, [], :start)

  # A number at the start or when we're expecting more after , or :
  defp collect_uid_set_tokens([{:number, _} = t | rest], acc, state)
       when state in [:start, :need_more] do
    collect_uid_set_tokens(rest, [t | acc], :need_continuation)
  end

  # After a number, an atom starting with , or : continues the uid-set
  defp collect_uid_set_tokens([{:atom, <<c, _::binary>>} = t | rest], acc, :need_continuation)
       when c in ~c",:" do
    # Check if the atom ends with , or : (needs more) or a digit (complete element)
    last_char = :binary.last(elem(t, 1))

    next_state =
      if last_char in ~c",:" do
        :need_more
      else
        :need_continuation
      end

    collect_uid_set_tokens(rest, [t | acc], next_state)
  end

  # An atom that is a complete uid-set by itself (e.g., "1:3,5")
  defp collect_uid_set_tokens([{:atom, s} = t | rest], [], :start) do
    if Regex.match?(~r/^[0-9,:*]+$/, s) do
      last_char = :binary.last(s)

      next_state =
        if last_char in ~c",:" do
          :need_more
        else
          :need_continuation
        end

      collect_uid_set_tokens(rest, [t], next_state)
    else
      {[], [{:atom, s} | rest]}
    end
  end

  defp collect_uid_set_tokens(rest, acc, _), do: {Enum.reverse(acc), rest}

  defp uid_set_tokens_to_string(tokens) do
    Enum.map(tokens, fn
      {:number, n} -> Integer.to_string(n)
      {:atom, s} -> s
    end)
    |> Enum.join("")
  end

  defp collect_atoms(tokens) do
    tokens
    |> Enum.take_while(&(&1 != :crlf))
    |> Enum.filter(fn
      {:atom, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:atom, v} -> v end)
  end

  defp collect_until_rbracket(tokens) do
    {before, remaining} = Enum.split_while(tokens, &(&1 != :rbracket))

    values =
      Enum.map(before, fn
        {:atom, v} -> v
        {:number, v} -> Integer.to_string(v)
        {:quoted_string, v} -> v
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    remaining =
      case remaining do
        [:rbracket | r] -> r
        r -> r
      end

    {values, remaining}
  end

  defp drop_until_after_rbracket([:rbracket | rest]), do: rest
  defp drop_until_after_rbracket([_ | rest]), do: drop_until_after_rbracket(rest)
  defp drop_until_after_rbracket([]), do: []

  defp tokens_to_text(tokens) do
    tokens
    |> Enum.take_while(&(&1 != :crlf))
    |> Enum.map(fn
      {:atom, v} -> v
      {:number, v} -> Integer.to_string(v)
      {:quoted_string, v} -> v
      {:flag, v} -> v
      {:literal, v} -> v
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
