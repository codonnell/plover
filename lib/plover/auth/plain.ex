defmodule Plover.Auth.Plain do
  @moduledoc """
  SASL PLAIN authentication encoder.

  RFC 4616: message = [authzid] UTF8NUL authcid UTF8NUL passwd
  """

  @doc """
  Encodes credentials as a Base64-encoded SASL PLAIN string.

  The format is `authzid NUL authcid NUL passwd` with an empty authorization
  identity, per RFC 4616.
  """
  @spec encode(String.t(), String.t()) :: String.t()
  def encode(username, password) do
    Base.encode64("\0" <> username <> "\0" <> password)
  end
end
