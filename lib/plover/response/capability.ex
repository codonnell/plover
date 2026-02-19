defmodule Plover.Response.Capability do
  @moduledoc """
  CAPABILITY response data.

  Returned as an untagged response and also used as a response code
  inside tagged and condition responses.

  RFC 9051 Section 7.2.2
  """

  defstruct [:capabilities]

  @type t :: %__MODULE__{
          capabilities: [String.t()]
        }
end
