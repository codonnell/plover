defmodule Plover.Response.Unhandled do
  @moduledoc """
  An unrecognized untagged response.

  Contains the raw token list for responses the parser does not
  have a dedicated handler for (e.g., extension-defined responses).
  """

  defstruct [:tokens]

  @type t :: %__MODULE__{
          tokens: [Plover.Protocol.Parser.token()]
        }
end
