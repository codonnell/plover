defmodule Plover.Response.Mailbox do
  @moduledoc """
  Mailbox-related response structures.
  """

  defmodule List do
    @moduledoc """
    A LIST response entry.

    RFC 9051 Section 7.2.2
    """

    defstruct [:delimiter, :name, flags: []]

    @type t :: %__MODULE__{
            flags: [atom()],
            delimiter: nil | String.t(),
            name: String.t()
          }
  end

  defmodule Status do
    @moduledoc """
    A STATUS response.

    RFC 9051 Section 7.2.4
    """

    defstruct [:name, :messages, :recent, :unseen, :uid_next, :uid_validity]

    @type t :: %__MODULE__{
            name: String.t(),
            messages: nil | non_neg_integer(),
            recent: nil | non_neg_integer(),
            unseen: nil | non_neg_integer(),
            uid_next: nil | pos_integer(),
            uid_validity: nil | pos_integer()
          }
  end

  defmodule Flags do
    @moduledoc """
    A FLAGS response.

    RFC 9051 Section 7.2.6
    """

    defstruct flags: []

    @type t :: %__MODULE__{
            flags: [atom()]
          }
  end

  defmodule Exists do
    @moduledoc """
    An EXISTS response indicating the number of messages in the mailbox.

    RFC 9051 Section 7.3.1
    """

    defstruct [:count]

    @type t :: %__MODULE__{
            count: non_neg_integer()
          }
  end
end
