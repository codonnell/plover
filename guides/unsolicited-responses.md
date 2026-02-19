# Unsolicited Responses

IMAP servers can send untagged responses at any time, not just in reply to
your commands. These **unsolicited responses** notify the client of changes
to the mailbox: new messages arriving, messages being expunged by another
session, or flag changes made elsewhere. The `:on_unsolicited_response`
callback gives your application visibility into these notifications.

## What are unsolicited responses?

[RFC 9051 Section 5.2](https://www.rfc-editor.org/rfc/rfc9051#section-5.2)
requires servers to send mailbox size updates automatically and recommends
sending flag updates as well. The three most important unsolicited
responses for mailbox state are:

- **EXISTS** — the mailbox message count changed (usually a new message
  arrived). Example: `* 42 EXISTS`
- **EXPUNGE** — a message was removed from the mailbox (by another client
  or session). Example: `* 7 EXPUNGE`
- **FETCH** — flags on a message changed (e.g., marked as read by another
  device). Example: `* 5 FETCH (FLAGS (\Seen))`

These are the ones most applications need to react to in real time.

However, the spec permits **any** untagged response to arrive unsolicited
([RFC 9051 Section 5.3](https://www.rfc-editor.org/rfc/rfc9051#section-5.3)).
Other examples include:

- **LIST** — another session created, deleted, or renamed a mailbox
- **FLAGS** — the set of available flags on the mailbox changed
- **OK/BAD/BYE** — status responses with response codes (e.g., ALERT
  codes, impending shutdown)
- Extension-defined responses

All untagged responses can arrive during any command, or even between
commands if the server has pending notifications.

## How Plover handles them

By default, Plover accumulates unsolicited responses on the pending
command's response list. They're included in the command result alongside
expected responses. When you're in [IDLE mode](https://www.rfc-editor.org/rfc/rfc9051#section-6.3.13),
the IDLE callback handles EXISTS, EXPUNGE, and FETCH instead.

The `:on_unsolicited_response` option adds a callback that fires for
**all** untagged responses **outside of IDLE**, giving you a single place
to react to server-initiated notifications regardless of which command
triggered them. Responses still accumulate on pending commands as
before — the callback is additive.

## Setting up the callback

Pass a function to `Plover.connect/2` or `Plover.connect/3`:

```elixir
{:ok, conn} =
  Plover.connect("imap.example.com",
    on_unsolicited_response: fn response ->
      IO.inspect(response, label: "unsolicited")
    end
  )
```

The callback receives a struct for every untagged response Plover
parses. All response types are documented in `Plover.Types.untagged_response`.
Always include a catch-all clause for forward compatibility:

```elixir
on_unsolicited_response: fn
  %Plover.Response.Mailbox.Exists{count: count} ->
    Logger.info("Mailbox now has #{count} messages")

  %Plover.Response.Message.Expunge{seq: seq} ->
    Logger.info("Message #{seq} was expunged")

  %Plover.Response.Message.Fetch{seq: seq, attrs: attrs} ->
    Logger.info("Message #{seq} flags changed: #{inspect(attrs.flags)}")

  _other ->
    :ok
end
```

## What the callback receives

The callback is invoked for every untagged response outside of IDLE.
The most important ones to handle:

| Response | Struct | Key fields | When it fires |
|---|---|---|---|
| EXISTS | `%Mailbox.Exists{}` | `count` — total messages in mailbox | A new message arrived |
| EXPUNGE | `%Message.Expunge{}` | `seq` — sequence number of removed message | A message was permanently removed |
| FETCH | `%Message.Fetch{}` | `seq`, `attrs` (map with `:flags` etc.) | Flags changed on a message |

Other responses you may see:

| Response | Struct | Key fields |
|---|---|---|
| FLAGS | `%Mailbox.Flags{}` | `flags` — available flags on the mailbox |
| LIST | `%Mailbox.List{}` | `name`, `flags`, `delimiter` |
| STATUS | `%Mailbox.Status{}` | `name`, `messages`, `unseen`, etc. |
| CAPABILITY | `%Capability{}` | `capabilities` — list of capability strings |
| OK/NO/BAD | `%Condition{}` | `status`, `code` (response code), `text` |
| BYE | `%Condition{}` | `status: :bye`, `text` |
| ENABLED | `%Enabled{}` | `capabilities` — list of enabled extensions |
| (unknown) | `%Unhandled{}` | `tokens` — raw token list |

## Common patterns

### Tracking mailbox state

```elixir
{:ok, agent} = Agent.start_link(fn -> %{count: 0} end)

{:ok, conn} =
  Plover.connect("imap.example.com",
    on_unsolicited_response: fn
      %Plover.Response.Mailbox.Exists{count: count} ->
        Agent.update(agent, &Map.put(&1, :count, count))

      %Plover.Response.Message.Expunge{} ->
        Agent.update(agent, &Map.update!(&1, :count, fn c -> max(c - 1, 0) end))

      _ ->
        :ok
    end
  )
```

### Sending to a process

If you need to do more than lightweight bookkeeping, forward notifications
to a dedicated process to keep the callback fast:

```elixir
{:ok, conn} =
  Plover.connect("imap.example.com",
    on_unsolicited_response: fn response ->
      send(MyApp.MailboxWatcher, {:imap_notification, response})
    end
  )
```

The callback runs inside the `Plover.Connection` GenServer process, so it
should return quickly to avoid blocking IMAP command processing.

## Relationship with IDLE

When the connection is in [IDLE mode](https://www.rfc-editor.org/rfc/rfc9051#section-6.3.13),
EXISTS, EXPUNGE, and FETCH notifications are handled by the IDLE callback
passed to `Plover.idle/2`. The `:on_unsolicited_response` callback is
**not** invoked for those three during IDLE — only the IDLE callback
fires. Other untagged responses (FLAGS, LIST, etc.) are not delivered
during IDLE.

Once you call `Plover.idle_done/1` and resume normal commands, the
`:on_unsolicited_response` callback takes over again.

```elixir
# During normal commands: on_unsolicited_response fires
{:ok, _} = Plover.noop(conn)

# During IDLE: idle callback fires, on_unsolicited_response does not
:ok = Plover.idle(conn, fn response -> handle_idle(response) end)
```

## Further reading

- [RFC 9051 Section 5.2](https://www.rfc-editor.org/rfc/rfc9051#section-5.2) — Mailbox size and message status updates
- [RFC 9051 Section 5.3](https://www.rfc-editor.org/rfc/rfc9051#section-5.3) — Response when no command in progress
- [RFC 9051 Section 7.3.1](https://www.rfc-editor.org/rfc/rfc9051#section-7.3.1) — EXISTS response
- [RFC 9051 Section 7.5.1](https://www.rfc-editor.org/rfc/rfc9051#section-7.5.1) — EXPUNGE response
