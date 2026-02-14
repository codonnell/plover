defmodule Plover.Command do
  @moduledoc """
  Represents an IMAP command to be sent to the server.

  RFC 9051 Section 2.2.1 - Client Protocol Sender and Server Protocol Receiver
  """

  defstruct [:tag, :name, args: []]

  @type t :: %__MODULE__{
          tag: String.t(),
          name: String.t(),
          args: list()
        }
end
