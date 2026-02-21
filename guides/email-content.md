# Email Content

This guide walks through fetching an email's content over IMAP and decoding
it into usable text or binary data. It assumes you have a connection in the
selected state and know the UID of the message you want to read.

## How email content works in IMAP

Email messages aren't flat blobs of text. A single message is a tree of
[MIME](https://www.rfc-editor.org/rfc/rfc2045) parts, each with its own
content type, encoding, and charset. A typical message with both a plain text
and HTML version plus a PDF attachment looks like this:

```
multipart/mixed
├── multipart/alternative
│   ├── text/plain; charset="UTF-8"         (the plain text body)
│   └── text/html; charset="UTF-8"          (the HTML body)
└── application/pdf; name="report.pdf"      (an attachment)
```

IMAP gives you access to this structure without downloading the entire
message (see [RFC 9051 Section 6.4.5 — FETCH Command](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.5)).
The workflow is:

1. **Fetch the body structure** — ask the server for the MIME tree
2. **Find the part you want** — e.g. the `text/plain` part, or all attachments
3. **Fetch that part's content** — download just the bytes for that section
4. **Decode it** — reverse the transfer encoding and convert the charset

## Step 1: Fetch the body structure

The [BODYSTRUCTURE](https://www.rfc-editor.org/rfc/rfc9051#section-7.5.2)
fetch item is a description of the message's MIME tree. Fetching it is
cheap — the server returns metadata only, not the actual content.

```elixir
{:ok, [msg]} = Plover.uid_fetch(conn, uid, [:body_structure])
bs = msg.attrs.body_structure
```

`bs` is a `%Plover.Response.BodyStructure{}` struct. For a single-part
message (plain text, no attachments), it represents the whole message
directly. For [multipart](https://www.rfc-editor.org/rfc/rfc2046#section-5.1)
messages, it has a `:parts` list containing child structs, which can
themselves be multipart — forming the tree shown above.

Key fields on each part:

| Field | Example | Meaning |
|---|---|---|
| `type` | `"TEXT"` | MIME major type |
| `subtype` | `"PLAIN"` | MIME minor type |
| `params` | `%{"CHARSET" => "UTF-8"}` | Content-type parameters |
| `encoding` | `"QUOTED-PRINTABLE"` | Transfer encoding |
| `size` | `4286` | Size in bytes |
| `disposition` | `{"ATTACHMENT", %{"FILENAME" => "report.pdf"}}` | Disposition and params |
| `parts` | `[%BodyStructure{}, ...]` | Child parts (multipart only) |

## Step 2: Find the parts you need

`Plover.BodyStructure` provides helpers to navigate the tree without manual
recursion.

### Listing all parts

`flatten/1` returns every leaf part with its **section path** — the string
you'll pass to the server to fetch that part's content.

```elixir
alias Plover.BodyStructure, as: BS

parts = BS.flatten(bs)
# [
#   {"1.1", %BodyStructure{type: "TEXT", subtype: "PLAIN", ...}},
#   {"1.2", %BodyStructure{type: "TEXT", subtype: "HTML", ...}},
#   {"2",   %BodyStructure{type: "APPLICATION", subtype: "PDF", ...}}
# ]
```

Section paths follow IMAP's numbering convention (defined in
[RFC 9051 Section 6.4.5.1](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.5.1)):
children of a multipart are numbered starting at 1, and nested levels are
dot-separated. In the example above, `"1.1"` means "first child of the
first child" — the text/plain part inside the multipart/alternative.

For a single-part message (no multipart wrapper), the section path is `""`.

### Finding parts by MIME type

`find_parts/2` searches the tree for parts matching a type pattern:

```elixir
# Exact match
[{section, part}] = BS.find_parts(bs, "text/plain")

# Wildcard — all text parts
text_parts = BS.find_parts(bs, "text/*")

# No match returns an empty list
[] = BS.find_parts(bs, "audio/mpeg")
```

Matching is case-insensitive.

### Listing attachments

`attachments/1` returns a summary of each attachment part:

```elixir
atts = BS.attachments(bs)
# [%{
#   section: "2",
#   filename: "report.pdf",
#   type: "APPLICATION/PDF",
#   size: 45678,
#   encoding: "BASE64"
# }]
```

A part is considered an attachment if its MIME disposition is `ATTACHMENT`,
or if it has a filename parameter and isn't explicitly `INLINE`.

## Step 3: Fetch and decode the content

`Plover.fetch_parts/3` handles fetching and decoding in one call. Pass it
the `{section, part}` tuples from step 2 — it fetches the raw content using
[`BODY.PEEK`](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.5) (which
does not set the `\Seen` flag), then decodes each part automatically:

```elixir
parts = BS.find_parts(bs, "text/plain")
{:ok, [{section, text}]} = Plover.fetch_parts(conn, uid, parts)
```

`text` is a decoded UTF-8 string, ready to use.

For text parts (`text/*`), `fetch_parts` applies both
[transfer decoding](https://www.rfc-editor.org/rfc/rfc2045#section-6)
(base64, quoted-printable) and
[charset conversion](https://www.rfc-editor.org/rfc/rfc2046#section-4.1.2)
(e.g. ISO-8859-1 to UTF-8). For all other parts (images, PDFs, etc.), it
applies transfer decoding only, returning raw bytes.

You can fetch multiple parts at once — the results come back in the same
order as the input:

```elixir
text_parts = BS.find_parts(bs, "text/*")
{:ok, decoded} = Plover.fetch_parts(conn, uid, text_parts)
# [{"1.1", "plain text content..."}, {"1.2", "<html>..."}]
```

### How content is encoded on the wire

The raw content stored on IMAP servers is encoded in two layers, which
`fetch_parts` reverses for you:

1. **[Transfer encoding](https://www.rfc-editor.org/rfc/rfc2045#section-6)** —
   how the bytes are represented for safe transport:

    | Encoding | What it does | Common on |
    |---|---|---|
    | `BASE64` | [Encodes arbitrary bytes as ASCII characters](https://www.rfc-editor.org/rfc/rfc2045#section-6.8) | Attachments, HTML bodies |
    | `QUOTED-PRINTABLE` | [Escapes non-ASCII bytes as `=XX` hex pairs](https://www.rfc-editor.org/rfc/rfc2045#section-6.7) | Text bodies with accented characters |
    | `7BIT` / `8BIT` / `BINARY` | No encoding, raw content | Plain ASCII text |

2. **[Charset](https://www.rfc-editor.org/rfc/rfc2046#section-4.1.2)** —
   the byte encoding used for text content. `Plover.Content` converts
   these to UTF-8:

    - **UTF-8** / **US-ASCII** — passed through unchanged
    - **ISO-8859-1** (Latin-1) — common in older European email
    - **Windows-1252** — similar to Latin-1 with extra characters like curly quotes

    Unknown charsets are returned as-is without error, so you won't crash
    on unusual encodings — but the text may need further processing.

### Manual decoding

If you need lower-level control — for example, to stream content to disk
without holding it in memory — you can fetch and decode parts yourself:

```elixir
[{section, part}] = BS.find_parts(bs, "text/plain")

{:ok, [msg]} = Plover.uid_fetch(conn, uid, [{:body_peek, section}])
raw = msg.attrs.body[section]

encoding = BS.encoding(part)  # e.g. "QUOTED-PRINTABLE"
charset = BS.charset(part)    # e.g. "ISO-8859-1"
{:ok, text} = Plover.Content.decode(raw, encoding, charset)
```

For binary attachments, skip charset conversion with the two-argument form:

```elixir
{:ok, pdf_bytes} = Plover.Content.decode(raw, att.encoding)
File.write!("report.pdf", pdf_bytes)
```

## Putting it all together

### Reading the text body of a message

```elixir
alias Plover.BodyStructure, as: BS

# 1. Get the structure
{:ok, [msg]} = Plover.uid_fetch(conn, uid, [:body_structure])
bs = msg.attrs.body_structure

# 2. Find the text/plain part (fall back to text/html)
parts =
  case BS.find_parts(bs, "text/plain") do
    [_ | _] = found -> found
    [] ->
      case BS.find_parts(bs, "text/html") do
        [_ | _] = found -> found
        [] -> raise "No text content found"
      end
  end

# 3. Fetch and decode
{:ok, [{_section, text}]} = Plover.fetch_parts(conn, uid, parts)
```

### Downloading all attachments

```elixir
alias Plover.BodyStructure, as: BS

{:ok, [msg]} = Plover.uid_fetch(conn, uid, [:body_structure])
bs = msg.attrs.body_structure

for att <- BS.attachments(bs) do
  {:ok, part} = BS.get_part(bs, att.section)
  {:ok, [{_, data}]} = Plover.fetch_parts(conn, uid, [{att.section, part}])
  File.write!(att.filename, data)
end
```

### Fetching everything at once

If you know you'll need the structure, text, and envelope, fetch the
metadata together to avoid extra round trips:

```elixir
alias Plover.BodyStructure, as: BS

{:ok, [msg]} = Plover.uid_fetch(conn, uid, [:body_structure, :envelope, :flags])
bs = msg.attrs.body_structure
env = msg.attrs.envelope

# Find and fetch the text part
parts = BS.find_parts(bs, "text/plain")
{:ok, [{_section, text}]} = Plover.fetch_parts(conn, uid, parts)

IO.puts("From: #{hd(env.from).mailbox}@#{hd(env.from).host}")
IO.puts("Subject: #{env.subject}")
IO.puts("---")
IO.puts(text)
```

Note that you always need two fetches: one for the body structure (to learn
the section paths), and one for the actual content (using those paths). The
body structure itself is just metadata — the server won't include the raw
bytes until you ask for a specific section.

### Fetching content for many messages

When processing a batch of messages — for example, rendering a mailbox
view with preview snippets — use `Plover.fetch_parts_batch/3` to fetch
and decode parts for multiple UIDs concurrently. It pipelines the
underlying `UID FETCH` commands so you pay one round trip instead of N:

```elixir
alias Plover.BodyStructure, as: BS

# 1. Fetch body structures for a range of messages
{:ok, messages} = Plover.uid_fetch(conn, "1:20", [:body_structure, :uid])

# 2. Build a list of {uid, [{section, part}]} for each message
parts_by_uid =
  for msg <- messages do
    bs = msg.attrs.body_structure
    parts = BS.find_parts(bs, "text/plain")
    {to_string(msg.attrs.uid), parts}
  end

# 3. Fetch and decode all parts in parallel (default: 30 concurrent)
{:ok, results} = Plover.fetch_parts_batch(conn, parts_by_uid)

# results is a map: %{"uid" => [{"section", "decoded text"}, ...]}
for {uid, [{_section, text} | _]} <- results do
  IO.puts("UID #{uid}: #{String.slice(text, 0, 80)}...")
end
```

The `:max_concurrency` option controls how many `UID FETCH` commands can
be in-flight at once (default: 30). Lower it if the server imposes
connection-level rate limits:

```elixir
Plover.fetch_parts_batch(conn, parts_by_uid, max_concurrency: 5)
```

If any individual fetch fails, the entire batch returns `{:error, reason}`
immediately.

## Further reading

- [RFC 9051](https://www.rfc-editor.org/rfc/rfc9051) — IMAP4rev2, the protocol Plover implements
  - [Section 6.4.5](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.5) — FETCH command and data items
  - [Section 6.4.5.1](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.5.1) — Section specifier syntax (`"1.2"`, etc.)
  - [Section 6.4.9](https://www.rfc-editor.org/rfc/rfc9051#section-6.4.9) — UID command (UID FETCH, UID SEARCH, etc.)
  - [Section 7.5.2](https://www.rfc-editor.org/rfc/rfc9051#section-7.5.2) — FETCH response (BODYSTRUCTURE, ENVELOPE, etc.)
- [RFC 2045](https://www.rfc-editor.org/rfc/rfc2045) — MIME Part One: format of message bodies
  - [Section 6.7](https://www.rfc-editor.org/rfc/rfc2045#section-6.7) — Quoted-Printable encoding
  - [Section 6.8](https://www.rfc-editor.org/rfc/rfc2045#section-6.8) — Base64 encoding
- [RFC 2046](https://www.rfc-editor.org/rfc/rfc2046) — MIME Part Two: media types
  - [Section 4.1.2](https://www.rfc-editor.org/rfc/rfc2046#section-4.1.2) — Charset parameter
  - [Section 5.1](https://www.rfc-editor.org/rfc/rfc2046#section-5.1) — Multipart media type
