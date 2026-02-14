defmodule Plover.Types do
  @moduledoc """
  Shared type definitions for the Plover IMAP client.
  """

  @type conn :: GenServer.server()

  @type sequence_set :: [{seq_number(), seq_number()}]
  @type seq_number :: pos_integer() | :star

  @type flag :: atom()

  @type mailbox_name :: String.t()

  @type fetch_attr ::
          :envelope
          | :flags
          | :uid
          | :body_structure
          | :internal_date
          | :rfc822_size
          | {:body, String.t()}
          | {:body_peek, String.t()}

  @type status_attr :: :messages | :recent | :unseen | :uid_next | :uid_validity

  @type store_action :: :set | :add | :remove
  @type store_silent :: boolean()
end
