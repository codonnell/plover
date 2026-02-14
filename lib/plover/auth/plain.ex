defmodule Plover.Auth.Plain do
  @moduledoc """
  SASL PLAIN authentication encoder.

  RFC 4616: message = [authzid] UTF8NUL authcid UTF8NUL passwd
  """

  @spec encode(String.t(), String.t()) :: String.t()
  def encode(username, password) do
    Base.encode64("\0" <> username <> "\0" <> password)
  end
end
