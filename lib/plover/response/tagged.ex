defmodule Plover.Response.Tagged do
  @moduledoc """
  A tagged server response (OK/NO/BAD).

  RFC 9051 Section 7.1
  """

  defstruct [:tag, :status, :code, :text]

  @type t :: %__MODULE__{
          tag: String.t(),
          status: :ok | :no | :bad,
          code: Plover.Types.response_code(),
          text: String.t()
        }
end
