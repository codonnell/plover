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
end
