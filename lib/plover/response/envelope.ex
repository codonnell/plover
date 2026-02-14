defmodule Plover.Response.Envelope do
  @moduledoc """
  The envelope structure of a message.

  RFC 9051 Section 2.3.5
  """

  defstruct [
    :date,
    :subject,
    :from,
    :sender,
    :reply_to,
    :to,
    :cc,
    :bcc,
    :in_reply_to,
    :message_id
  ]

  @type t :: %__MODULE__{
          date: nil | String.t(),
          subject: nil | String.t(),
          from: [Plover.Response.Address.t()],
          sender: [Plover.Response.Address.t()],
          reply_to: [Plover.Response.Address.t()],
          to: [Plover.Response.Address.t()],
          cc: [Plover.Response.Address.t()],
          bcc: [Plover.Response.Address.t()],
          in_reply_to: nil | String.t(),
          message_id: nil | String.t()
        }
end
