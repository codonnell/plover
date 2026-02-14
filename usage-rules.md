# Plover Usage Rules

## Connection Lifecycle

- Every connection is a GenServer process. `Plover.connect/2` returns `{:ok, pid}`.
- The connection follows the IMAP state machine: `:not_authenticated` -> `:authenticated` -> `:selected` -> `:logout`.
- You must authenticate (LOGIN or AUTHENTICATE) before selecting a mailbox.
- You must select a mailbox before using FETCH, SEARCH, STORE, COPY, MOVE, or EXPUNGE.
- `Plover.logout/1` stops the GenServer. Do not use the `conn` pid after logout.

## API Conventions

- All command functions return `{:ok, result}` or `{:error, %Plover.Response.Tagged{}}`.
- The error tuple contains the full tagged response with `.status` (`:no` or `:bad`), `.code`, and `.text`.
- `Plover.idle/2` returns `:ok` (not `{:ok, _}`) once the server acknowledges the IDLE state.

## Fetch Attributes

Pass fetch attributes as a list of atoms or tuples:

```elixir
Plover.fetch(conn, "1:5", [:envelope, :flags, :uid])
Plover.fetch(conn, "1", [{:body, ""}, :uid])           # full body
Plover.fetch(conn, "1", [{:body_peek, "HEADER"}, :uid]) # headers without setting \Seen
```

Available atoms: `:envelope`, `:flags`, `:uid`, `:body_structure`, `:internal_date`, `:rfc822_size`.
Tuples: `{:body, section}`, `{:body_peek, section}` where section is a string like `""`, `"HEADER"`, `"1"`.

## FETCH Results

`Plover.fetch/3` returns `{:ok, [%Plover.Response.Message.Fetch{}]}`. Each struct has:

- `.seq` - sequence number
- `.attrs` - map with keys like `:uid`, `:flags`, `:envelope`, `:body_structure`, `:body`, `:rfc822_size`
- `.attrs.flags` is a list of atoms: `:seen`, `:answered`, `:flagged`, `:deleted`, `:draft`
- `.attrs.envelope` is a `%Plover.Response.Envelope{}` with `.subject`, `.from`, `.to`, `.date`, `.message_id`, etc.
- `.attrs.body` is a map of `%{section_string => binary_data}`

## STORE Flags

The `action` parameter is an atom:

```elixir
Plover.store(conn, "1:3", :add, [:seen])       # +FLAGS (\Seen)
Plover.store(conn, "1:3", :remove, [:deleted])  # -FLAGS (\Deleted)
Plover.store(conn, "1:3", :set, [:seen, :flagged]) # FLAGS (\Seen \Flagged)
```

## SEARCH

`Plover.search/2` takes a raw IMAP search criteria string:

```elixir
Plover.search(conn, "UNSEEN")
Plover.search(conn, "FROM \"user@example.com\" SINCE 1-Jan-2024")
```

Returns `{:ok, %Plover.Response.ESearch{}}` with `.min`, `.max`, `.count`, `.all` fields.

## UID Commands

All UID variants mirror their non-UID counterparts:

```elixir
Plover.uid_fetch(conn, "500:510", [:flags, :uid])
Plover.uid_store(conn, "500", :add, [:seen])
Plover.uid_copy(conn, "500:502", "Archive")
Plover.uid_move(conn, "500:502", "Trash")
Plover.uid_search(conn, "ALL")
Plover.uid_expunge(conn, "500,501")
```

## APPEND

```elixir
Plover.append(conn, "INBOX", message_binary)
Plover.append(conn, "Drafts", message_binary, flags: [:seen, :draft], date: "14-Jul-2024 02:44:25 -0700")
```

## IDLE

```elixir
:ok = Plover.idle(conn, fn
  %Plover.Response.Mailbox.Exists{count: n} -> IO.puts("Now #{n} messages")
  %Plover.Response.Message.Expunge{seq: n} -> IO.puts("Message #{n} expunged")
  %Plover.Response.Message.Fetch{} = fetch -> IO.inspect(fetch)
end)

# When ready to stop:
{:ok, _} = Plover.idle_done(conn)
```

## Testing with Mock Transport

Use `Plover.Transport.Mock` to test without a real IMAP server:

```elixir
{:ok, socket} = Plover.Transport.Mock.connect("imap.example.com", 993, [])
Plover.Transport.Mock.enqueue(socket, "* OK Server ready\r\n")
{:ok, conn} = Plover.connect("imap.example.com", 993, transport: Plover.Transport.Mock, socket: socket)

# Enqueue the response BEFORE issuing the command
Plover.Transport.Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
{:ok, _} = Plover.login(conn, "user", "pass")
```

Important: always enqueue the expected server response before calling the command that triggers it. Tags are sequential: `A0001`, `A0002`, `A0003`, etc.

## Common Mistakes

- Do not call commands out of state order. SELECT before LOGIN will return an error from the server.
- IDLE blocks the connection for other commands. Call `idle_done/1` before issuing another command.
- Sequence numbers are not stable across sessions. Use UID commands for persistent references.
- `Plover.search/2` takes a raw criteria string, not a structured query. The string is sent directly to the server.
