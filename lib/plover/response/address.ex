defmodule Plover.Response.Address do
  @moduledoc """
  An email address structure.

  RFC 9051 Section 2.3.5 - addr fields: name, adl, mailbox, host
  """

  defstruct [:name, :adl, :mailbox, :host]

  @type t :: %__MODULE__{
          name: nil | String.t(),
          adl: nil | String.t(),
          mailbox: nil | String.t(),
          host: nil | String.t()
        }
end
