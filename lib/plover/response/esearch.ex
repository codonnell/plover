defmodule Plover.Response.ESearch do
  @moduledoc """
  ESEARCH response data.

  RFC 9051 Section 7.3.4
  """

  defstruct [:tag, :uid, :min, :max, :all, :count]

  @type t :: %__MODULE__{
          tag: nil | String.t(),
          uid: boolean(),
          min: nil | pos_integer(),
          max: nil | pos_integer(),
          all: nil | String.t(),
          count: nil | non_neg_integer()
        }
end
