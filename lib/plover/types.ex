defmodule Plover.Types do
  @moduledoc """
  Shared type definitions for the Plover IMAP client.
  """

  @typedoc "A connection process identifier."
  @type conn :: GenServer.server()

  @typedoc "A parsed sequence set as a list of `{from, to}` range tuples."
  @type sequence_set :: [{seq_number(), seq_number()}]

  @typedoc "A sequence number: a positive integer or `:star` (representing `*`)."
  @type seq_number :: pos_integer() | :star

  @typedoc "A message flag atom (e.g., `:seen`, `:flagged`, `:deleted`)."
  @type flag :: atom()

  @typedoc "An IMAP mailbox name."
  @type mailbox_name :: String.t()

  @typedoc """
  A FETCH data item to request.

  Atoms request standard attributes. Tuple forms request body content:

    * `{:body, section}` - fetches the section and sets the `\\Seen` flag
    * `{:body_peek, section}` - fetches the section without setting `\\Seen`
  """
  @type fetch_attr ::
          :envelope
          | :flags
          | :uid
          | :body_structure
          | :internal_date
          | :rfc822_size
          | {:body, String.t()}
          | {:body_peek, String.t()}

  @typedoc "A STATUS attribute to query on a mailbox."
  @type status_attr :: :messages | :recent | :unseen | :uid_next | :uid_validity

  @typedoc "How flags are applied in a STORE command."
  @type store_action :: :set | :add | :remove

  @typedoc "Whether the STORE command should suppress untagged FETCH responses."
  @type store_silent :: boolean()

  @typedoc """
  A response code from a server status response (RFC 9051 §7.1).

  Data codes carry a typed value. No-data codes are `{name, nil}` tuples —
  common names include `:alert`, `:parse`, `:read_only`, `:read_write`,
  `:try_create`, `:closed`, `:authentication_failed`, `:expired`,
  `:contact_admin`, `:no_perm`, `:in_use`, `:over_quota`, `:nonexistent`,
  and others from RFC 9051 §7.1. Unrecognized codes from extensions are
  `{atom(), nil | String.t()}`.
  """
  @type response_code ::
          nil
          | Plover.Response.Capability.t()
          | {:permanent_flags, [flag()]}
          | {:uid_next, pos_integer()}
          | {:uid_validity, pos_integer()}
          | {:append_uid, {pos_integer(), pos_integer()}}
          | {:copy_uid, {pos_integer(), String.t(), String.t()}}
          | {atom(), nil | String.t()}

  @typedoc "An untagged server response passed to the `:on_unsolicited_response` callback."
  @type untagged_response ::
          Plover.Response.Capability.t()
          | Plover.Response.Condition.t()
          | Plover.Response.Enabled.t()
          | Plover.Response.Mailbox.Exists.t()
          | Plover.Response.Mailbox.Flags.t()
          | Plover.Response.Mailbox.List.t()
          | Plover.Response.Mailbox.Status.t()
          | Plover.Response.Message.Expunge.t()
          | Plover.Response.Message.Fetch.t()
          | Plover.Response.ESearch.t()
          | Plover.Response.Unhandled.t()
end
