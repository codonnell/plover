defmodule Plover.Response.Enabled do
  @moduledoc """
  ENABLED response data.

  Returned after a successful ENABLE command listing the extensions
  that were activated.

  RFC 9051 Section 7.2.1
  """

  defstruct [:capabilities]

  @type t :: %__MODULE__{
          capabilities: [String.t()]
        }
end
