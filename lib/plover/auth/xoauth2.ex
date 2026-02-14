defmodule Plover.Auth.XOAuth2 do
  @moduledoc """
  Google XOAUTH2 authentication encoder.

  Format: "user=" user "\\x01auth=Bearer " token "\\x01\\x01"
  """

  @doc """
  Encodes credentials as a Base64-encoded XOAUTH2 string.

  The format is `user=<user>^Aauth=Bearer <token>^A^A` where `^A` is `\\x01`.
  """
  @spec encode(String.t(), String.t()) :: String.t()
  def encode(username, token) do
    Base.encode64("user=" <> username <> "\x01auth=Bearer " <> token <> "\x01\x01")
  end
end
