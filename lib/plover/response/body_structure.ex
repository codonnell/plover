defmodule Plover.Response.BodyStructure do
  @moduledoc """
  The body structure of a message.

  RFC 9051 Section 2.3.6
  """

  defstruct [
    :type,
    :subtype,
    :id,
    :description,
    :encoding,
    :size,
    :lines,
    :md5,
    :disposition,
    :language,
    :location,
    :envelope,
    params: %{},
    parts: [],
    extension: []
  ]

  @type t :: %__MODULE__{
          type: nil | String.t(),
          subtype: nil | String.t(),
          params: map(),
          id: nil | String.t(),
          description: nil | String.t(),
          encoding: nil | String.t(),
          size: nil | non_neg_integer(),
          lines: nil | non_neg_integer(),
          md5: nil | String.t(),
          disposition: nil | {String.t(), map()},
          language: nil | [String.t()],
          location: nil | String.t(),
          envelope: nil | Plover.Response.Envelope.t(),
          parts: [t()],
          extension: list()
        }
end
