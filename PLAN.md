# Plover: IMAP4rev2 Client Implementation Plan

## Context

Plover is a greenfield Elixir project that needs an IMAP4rev2 (RFC 9051) client library. The goal is a well-tested, idiomatic Elixir library covering the common subset of IMAP operations: connect over implicit TLS, authenticate (PLAIN/LOGIN/XOAUTH2), manage mailboxes, fetch/search/store messages, and IDLE for real-time updates.

## Architecture Overview

Four layers, each depending only on layers below:

```
  Plover (public API)
    |
  Plover.Connection (GenServer per connection)
    |
  Plover.Protocol (tokenizer, parser, command builder)
    |
  Plover.Transport (behaviour: SSL for prod, Mock for tests)
```

## Module Structure

```
lib/plover.ex                              # Public API facade
lib/plover/
  command.ex                               # %Command{tag, name, args} struct
  types.ex                                 # Shared typespecs
  connection.ex                            # GenServer: socket + state machine + dispatch
  connection/state.ex                      # Connection state struct
  transport.ex                             # Behaviour: connect/send/close/setopts/controlling_process
  transport/ssl.ex                         # :ssl implementation (production)
  transport/mock.ex                        # Process-based mock (testing)
  protocol/
    tokenizer.ex                           # Binary -> token stream
    parser.ex                              # Tokens -> response structs
    command_builder.ex                     # Commands -> iodata for wire
    sequence_set.ex                        # Parse/format sequence sets
  response.ex                              # Top-level response module
  response/
    tagged.ex                              # %Tagged{tag, status, code, text}
    continuation.ex                        # %Continuation{text, base64}
    envelope.ex                            # %Envelope{date, subject, from, ...}
    address.ex                             # %Address{name, adl, mailbox, host}
    body_structure.ex                      # %BodyStructure{type, subtype, parts, ...}
    esearch.ex                             # %ESearch{tag, uid, min, max, all, count}
    mailbox.ex                             # List, Status, Flags, Exists structs
    message.ex                             # Fetch, Expunge structs
  auth/
    plain.ex                               # SASL PLAIN encoder
    xoauth2.ex                             # XOAUTH2 encoder
```

## GenServer Design

### State
```elixir
%State{
  transport: module(),          # SSL or Mock
  socket: any(),
  conn_state: :not_authenticated | :authenticated | :selected | :logout,
  tag_counter: integer(),       # Generates A0001, A0002, ...
  buffer: binary(),             # Unparsed data from socket
  pending: %{tag => %{from, command, responses}},  # In-flight commands
  idle_state: nil | %{tag, from, callback},
  capabilities: MapSet.t(),
  selected_mailbox: nil | String.t(),
  mailbox_info: nil | map()
}
```

### Message Flow
1. Client calls e.g. `Plover.select(conn, "INBOX")` -> `GenServer.call(conn, {:command, :select, ["INBOX"]})`
2. GenServer generates tag, builds command via CommandBuilder, sends over socket, stores pending entry, returns `{:noreply, state}`
3. Socket data arrives via `handle_info({:ssl, socket, data})` in `active: :once` mode
4. Buffer is appended and parsed. Untagged responses accumulate on the pending command. Tagged response completes it and replies to caller with `{:ok, %{status: :ok, data: [...]}}` or `{:error, ...}`
5. Special flows: IDLE (continuation + DONE), AUTHENTICATE (continuation challenges), APPEND (literal after continuation)

## Protocol Parser

### Tokenizer (`protocol/tokenizer.ex`)
Built with **NimbleParsec** (compile-time only — generates inline binary-matching code, zero runtime dep). Exposes a public `tokenize/1` function returning `{:ok, tokens, rest}` or `{:error, reason}`.

NimbleParsec combinators define individual token types:
- `atom_token`: 1+ ATOM-CHARs (not parens, space, CTL, wildcards, brackets, quotes, backslash, `{`)
- `number_token`: 1+ DIGITs, mapped to integer via `map({String, :to_integer, []})`
- `quoted_string`: DQUOTE, repeat of (TEXT-CHAR except `"` and `\`) or (`\` then `"` or `\`), DQUOTE — uses `reduce` to unescape
- `flag_token`: `\` followed by atom chars (e.g. `\Seen`, `\*`)
- `literal_header`: `{` digits optional(`+`) `}` CRLF — tagged to extract size and sync/non-sync flag
- Structural tokens: `(`, `)`, `[`, `]`, `*`, `+`, SP, CRLF — via `string/2` + `replace/3`

The top-level `response_line` combinator uses `repeat(choice([...all token types...]))` terminated by CRLF.

**Literal handling**: NimbleParsec parses the `{N}\r\n` header via the `literal_header` combinator. A `post_traverse` callback then uses the parsed size `N` to consume exactly N bytes from the remaining binary. If the buffer is too short, parsing fails and the caller knows the input is incomplete. The Connection module retains the buffer and retries on the next `active: :once` chunk.

Token types: `{:atom, bin}`, `{:number, int}`, `{:quoted_string, bin}`, `{:literal, bin}`, `{:flag, bin}`, `:lparen`, `:rparen`, `:lbracket`, `:rbracket`, `:star`, `:plus`, `:crlf`, `:nil`

### Parser (`protocol/parser.ex`)
Recursive-descent parser consuming the token list from the tokenizer. Dispatches on first token:
- `{:atom, tag}` -> tagged response (OK/NO/BAD with resp-text-code)
- `:star` -> untagged: number-prefixed (EXISTS/EXPUNGE/FETCH) or keyword (CAPABILITY/FLAGS/LIST/STATUS/ESEARCH/BYE/OK/NO/BAD)
- `:plus` -> continuation

This layer stays hand-written (not NimbleParsec) because it operates on token lists, not binaries, and the IMAP response grammar involves context-sensitive dispatch (e.g., FETCH attrs vary by type) that is cleaner as recursive functions than as combinators.

Key sub-parsers: `parse_envelope/1`, `parse_body_structure/1`, `parse_msg_att/1`, `parse_esearch/1`, `parse_resp_text_code/1`

### Command Builder (`protocol/command_builder.ex`)
Serializes `%Command{}` to iodata. Handles astring quoting rules (atom if safe chars only, quoted string otherwise, literal for binary data). APPEND returns `{first_part, literal_data}` tuple for continuation flow.

## Auth Encoders

- **PLAIN**: `Base.encode64("\0" <> user <> "\0" <> password)`
- **XOAUTH2**: `Base.encode64("user=" <> user <> "\x01auth=Bearer " <> token <> "\x01\x01")`

## Commands Implemented

| State | Commands |
|---|---|
| Any | CAPABILITY, NOOP, LOGOUT |
| Not Authenticated | LOGIN, AUTHENTICATE (PLAIN, XOAUTH2) |
| Authenticated | SELECT, EXAMINE, CREATE, DELETE, LIST, STATUS, APPEND, IDLE |
| Selected | CLOSE, UNSELECT, EXPUNGE, SEARCH, FETCH, STORE, COPY, MOVE |
| UID variants | UID FETCH, UID STORE, UID COPY, UID MOVE, UID SEARCH, UID EXPUNGE |

## Testing Strategy

### Dependencies (test-only)
- `stream_data ~> 1.1` for property-based tests
- `dialyxir ~> 1.4` for static analysis (dev only)

### Test Layers

**Layer 1 - Pure unit tests (no processes):**
- `tokenizer_test.exs`: Every token type, escaping, literals, incomplete buffers (~100 cases)
- `parser_test.exs`: Every response type, all FETCH data items, envelope, bodystructure, esearch (~80 cases)
- `command_builder_test.exs`: Every command, quoting rules, special characters (~40 cases)
- `sequence_set_test.exs`: Parsing/formatting various set forms (~20 cases)
- `plain_test.exs`, `xoauth2_test.exs`: Encoding correctness

**Layer 2 - Property-based tests (StreamData):**
- Tokenizer round-trip: generate tokens -> serialize -> tokenize -> assert match
- Sequence set round-trip: generate -> format -> parse -> assert match

**Layer 3 - Connection tests (mock transport):**
- `connection_test.exs`: Lifecycle, state transitions, tag generation, error handling

**Layer 4 - Integration flow tests (scripted mock server):**
- `login_flow_test.exs`, `select_flow_test.exs`, `fetch_flow_test.exs`
- `search_flow_test.exs`, `idle_flow_test.exs`, `error_handling_test.exs`, `uid_commands_test.exs`

### Mock Infrastructure (`test/support/`)
- `fake_imap_server.ex`: GenServer accepting scripted interactions
- `server_script.ex`: DSL for defining expected commands and responses
- `factory.ex`: Builds response binaries for tests

`mix.exs` adds `elixirc_paths(:test) -> ["lib", "test/support"]`

## Implementation Order

### Phase 1: Data Types & Protocol Foundation
Files: `types.ex`, `command.ex`, `response.ex`, all `response/*.ex`, `sequence_set.ex`
Tests: `sequence_set_test.exs`

### Phase 2: Tokenizer
Files: `protocol/tokenizer.ex`
Tests: `tokenizer_test.exs`, `tokenizer_property_test.exs`

### Phase 3: Parser
Files: `protocol/parser.ex`
Tests: `parser_test.exs`, `parser_property_test.exs`

### Phase 4: Command Builder
Files: `protocol/command_builder.ex`
Tests: `command_builder_test.exs`

### Phase 5: Auth Encoders
Files: `auth/plain.ex`, `auth/xoauth2.ex`
Tests: `plain_test.exs`, `xoauth2_test.exs`

### Phase 6: Transport Layer
Files: `transport.ex`, `transport/ssl.ex`, `transport/mock.ex`
Tests: `mock_test.exs`

### Phase 7: Connection GenServer (incremental)
Files: `connection.ex`, `connection/state.ex`
Tests: `connection_test.exs`
Build incrementally: greeting -> simple commands -> LOGIN -> AUTHENTICATE -> SELECT -> FETCH/STORE/SEARCH -> UID variants -> IDLE -> APPEND -> error handling -> state machine enforcement

### Phase 8: Public API
Files: Update `plover.ex` with full API, update `plover_test.exs`

### Phase 9: Integration Tests & Polish
Files: All `test/plover/integration/*.exs`, test support files
Update `mix.exs`: deps, elixirc_paths, extra_applications (`:ssl`, `:crypto`)

## Verification

1. `mix deps.get` - install stream_data
2. `mix test` - all tests pass
3. `mix dialyzer` - no warnings
4. Manual verification: connect to a real IMAP server (e.g. Gmail on port 993) using `iex -S mix`:
   ```elixir
   {:ok, conn} = Plover.connect("imap.gmail.com")
   {:ok, _} = Plover.authenticate_xoauth2(conn, "user@gmail.com", oauth_token)
   {:ok, mailboxes} = Plover.list(conn, "", "*")
   {:ok, info} = Plover.select(conn, "INBOX")
   {:ok, messages} = Plover.fetch(conn, "1:5", [:envelope, :flags, :uid])
   :ok = Plover.logout(conn)
   ```
