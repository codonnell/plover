defmodule Plover.Auth.XOAuth2 do
  @moduledoc """
  Google XOAUTH2 authentication encoder.

  Format: "user=" user "\\x01auth=Bearer " token "\\x01\\x01"
  """

  @spec encode(String.t(), String.t()) :: String.t()
  def encode(username, token) do
    Base.encode64("user=" <> username <> "\x01auth=Bearer " <> token <> "\x01\x01")
  end
end
