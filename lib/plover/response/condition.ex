defmodule Plover.Response.Condition do
  @moduledoc """
  An untagged status response (OK, NO, BAD, BYE, or PREAUTH).

  RFC 9051 Section 7.1
  """

  defstruct [:status, :code, :text]

  @type t :: %__MODULE__{
          status: :ok | :no | :bad | :bye | :preauth,
          code: Plover.Types.response_code(),
          text: String.t()
        }
end
