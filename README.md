# Plover

An IMAP4rev2 ([RFC 9051](https://www.rfc-editor.org/rfc/rfc9051)) client library for Elixir.

Plover provides a high-level API for connecting to IMAP servers over implicit TLS, authenticating, managing mailboxes, and fetching/searching/storing messages.

## Features

- Full IMAP4rev2 command set: LOGIN, AUTHENTICATE (PLAIN, XOAUTH2), SELECT, EXAMINE, FETCH, SEARCH, STORE, COPY, MOVE, IDLE, APPEND, and more
- UID variants for all message commands
- ESEARCH response parsing (MIN, MAX, COUNT, ALL)
- IDLE for real-time mailbox notifications
- Envelope, body structure, and flag parsing
- Each connection is a supervised GenServer with a clean state machine

## Quick Start

```elixir
# Connect over implicit TLS (port 993)
{:ok, conn} = Plover.connect("imap.example.com")

# Authenticate
{:ok, _} = Plover.login(conn, "user@example.com", "password")

# Select a mailbox
{:ok, _} = Plover.select(conn, "INBOX")

# Fetch messages
{:ok, messages} = Plover.fetch(conn, "1:5", [:envelope, :flags, :uid])

for msg <- messages do
  IO.puts("#{msg.attrs.uid}: #{msg.attrs.envelope.subject}")
end

# Search
{:ok, results} = Plover.search(conn, "UNSEEN")
IO.puts("#{results.count} unseen messages")

# IDLE for real-time updates
:ok = Plover.idle(conn, fn update -> IO.inspect(update) end)
# ... later ...
{:ok, _} = Plover.idle_done(conn)

# Clean up
{:ok, _} = Plover.logout(conn)
```

## Architecture

```
Plover              Public API facade
  |
Connection          GenServer: socket I/O, command dispatch, state machine
  |
Protocol            Tokenizer (NimbleParsec), Parser, Command Builder
  |
Transport           Behaviour: SSL (production) / Mock (testing)
```

## Installation

Add `plover` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:plover, "~> 0.1.0"}
  ]
end
```
