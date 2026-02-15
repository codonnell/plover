# Testing with Plover

Plover includes a mock transport (`Plover.Transport.Mock`) that lets you
test IMAP client code without connecting to a real server.

## Setup

No special configuration is needed. Create a mock socket in your test and
pass it to `Plover.connect/3` with the `transport: Mock` option:

```elixir
alias Plover.Transport.Mock

{:ok, socket} = Mock.connect("imap.example.com", 993, [])
Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
{:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)
```

## High-Level Mock API

The mock transport provides struct-based helpers that handle IMAP wire
encoding and tag tracking automatically.

### `enqueue_greeting/2`

Enqueue the initial server greeting. Does not consume a tag.

```elixir
Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2", "IDLE"])
Mock.enqueue_greeting(socket, text: "Server ready")
```

### `enqueue_response/3`

Enqueue a tagged response with optional untagged responses before it.
Tags are auto-generated (A0001, A0002, ...) to match the Connection's counter.

```elixir
# Simple OK response
Mock.enqueue_response(socket, :ok, text: "LOGIN completed")

# Response with code
Mock.enqueue_response(socket, :ok,
  code: {:capability, ["IMAP4rev2"]},
  text: "LOGIN completed"
)

# Response with untagged data
Mock.enqueue_response(socket, :ok,
  untagged: [
    %Mailbox.Exists{count: 172},
    %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
  ],
  code: {:read_write, nil},
  text: "SELECT completed"
)

# Error response
Mock.enqueue_response(socket, :no, text: "FETCH failed")
```

### `enqueue_continuation/2`

Enqueue a continuation response (`+`). Does not consume a tag.

```elixir
Mock.enqueue_continuation(socket, text: "Ready for literal data")
```

### Tag Auto-Tracking

The mock transport maintains its own tag counter starting at 1. Each call to
`enqueue_response/3` atomically generates the next tag (A0001, A0002, ...)
and increments the counter. This matches the Connection's tag generation, so
responses are always matched to the correct command.

`enqueue_greeting/2` and `enqueue_continuation/2` do not increment the counter
since greetings and continuations are untagged.

## Common Flows

### Login

```elixir
Mock.enqueue_response(socket, :ok,
  code: {:capability, ["IMAP4rev2"]},
  text: "LOGIN completed"
)
{:ok, _} = Plover.login(conn, "user", "pass")
```

### Select

```elixir
Mock.enqueue_response(socket, :ok,
  untagged: [
    %Mailbox.Exists{count: 10},
    %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
  ],
  code: {:read_write, nil},
  text: "SELECT completed"
)
{:ok, _} = Plover.select(conn, "INBOX")
```

### Fetch

```elixir
Mock.enqueue_response(socket, :ok,
  untagged: [
    %Message.Fetch{seq: 1, attrs: %{flags: [:seen], uid: 100}},
    %Message.Fetch{seq: 2, attrs: %{flags: [:seen, :flagged], uid: 101}}
  ],
  text: "FETCH completed"
)
{:ok, messages} = Plover.fetch(conn, "1:2", [:flags, :uid])
```

### Search

```elixir
Mock.enqueue_response(socket, :ok,
  untagged: [
    %ESearch{uid: true, all: "1:5", count: 5}
  ],
  text: "SEARCH completed"
)
{:ok, results} = Plover.search(conn, "ALL", uid: true)
```

### Error Responses

```elixir
Mock.enqueue_response(socket, :no, text: "Mailbox not found")
{:error, resp} = Plover.select(conn, "NonExistent")
assert resp.status == :no
```

## Low-Level API

You can use `Mock.enqueue/2` to enqueue raw IMAP wire strings when you
need precise control over the response format:

```elixir
Mock.enqueue(socket, "* OK [CAPABILITY IMAP4rev2] Server ready\r\n")
Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
```

## Complete Example

```elixir
defmodule MyApp.MailClientTest do
  use ExUnit.Case, async: true

  alias Plover.Transport.Mock
  alias Plover.Response.{Mailbox, Message}

  defp setup_selected do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev2"])
    {:ok, conn} = Plover.connect("imap.example.com", 993, transport: Mock, socket: socket)

    Mock.enqueue_response(socket, :ok,
      code: {:capability, ["IMAP4rev2"]},
      text: "LOGIN completed"
    )
    {:ok, _} = Plover.login(conn, "user", "pass")

    Mock.enqueue_response(socket, :ok,
      untagged: [
        %Mailbox.Exists{count: 10},
        %Mailbox.Flags{flags: [:answered, :flagged, :deleted, :seen, :draft]}
      ],
      code: {:read_write, nil},
      text: "SELECT completed"
    )
    {:ok, _} = Plover.select(conn, "INBOX")
    {conn, socket}
  end

  test "fetch messages" do
    {conn, socket} = setup_selected()

    Mock.enqueue_response(socket, :ok,
      untagged: [
        %Message.Fetch{seq: 1, attrs: %{flags: [:seen], uid: 100}},
        %Message.Fetch{seq: 2, attrs: %{flags: [:seen, :flagged], uid: 101}}
      ],
      text: "FETCH completed"
    )

    assert {:ok, messages} = Plover.fetch(conn, "1:2", [:flags, :uid])
    assert length(messages) == 2

    [msg1, msg2] = messages
    assert msg1.attrs.uid == 100
    assert :seen in msg1.attrs.flags
    assert msg2.attrs.uid == 101
    assert :flagged in msg2.attrs.flags
  end
end
```
