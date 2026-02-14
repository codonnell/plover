defmodule Plover.Response.Message do
  @moduledoc """
  Message-related response structures.
  """

  defmodule Fetch do
    @moduledoc """
    A FETCH response for a single message.

    RFC 9051 Section 7.4.2
    """

    defstruct [:seq, attrs: %{}]

    @type t :: %__MODULE__{
            seq: pos_integer(),
            attrs: map()
          }
  end

  defmodule Expunge do
    @moduledoc """
    An EXPUNGE response.

    RFC 9051 Section 7.5.1
    """

    defstruct [:seq]

    @type t :: %__MODULE__{
            seq: pos_integer()
          }
  end
end
