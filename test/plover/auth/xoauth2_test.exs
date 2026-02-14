defmodule Plover.Auth.XOAuth2Test do
  use ExUnit.Case, async: true

  alias Plover.Auth.XOAuth2

  # Google XOAUTH2 mechanism
  # Format: "user=" <user> "\x01auth=Bearer " <token> "\x01\x01"
  # Then base64-encoded

  test "encodes XOAUTH2 credentials" do
    encoded = XOAuth2.encode("user@example.com", "ya29.token123")
    decoded = Base.decode64!(encoded)
    assert decoded == "user=user@example.com\x01auth=Bearer ya29.token123\x01\x01"
  end

  test "result is valid base64" do
    encoded = XOAuth2.encode("user@example.com", "token")
    assert {:ok, _} = Base.decode64(encoded)
  end

  test "encodes with long OAuth token" do
    token = String.duplicate("a", 200)
    encoded = XOAuth2.encode("user@gmail.com", token)
    decoded = Base.decode64!(encoded)
    assert decoded == "user=user@gmail.com\x01auth=Bearer #{token}\x01\x01"
  end
end
