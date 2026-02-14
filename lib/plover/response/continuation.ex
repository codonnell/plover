defmodule Plover.Response.Continuation do
  @moduledoc """
  A continuation request response.

  RFC 9051 Section 7.5
  """

  defstruct [:text, :base64]

  @type t :: %__MODULE__{
          text: nil | String.t(),
          base64: nil | String.t()
        }
end
