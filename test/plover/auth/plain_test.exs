defmodule Plover.Auth.PlainTest do
  use ExUnit.Case, async: true

  alias Plover.Auth.Plain

  # RFC 4616 - SASL PLAIN mechanism
  # message = [authzid] UTF8NUL authcid UTF8NUL passwd
  # For simple auth (no authzid): "\0" <> user <> "\0" <> password, then base64

  test "encodes PLAIN credentials" do
    encoded = Plain.encode("user@example.com", "password123")
    decoded = Base.decode64!(encoded)
    assert decoded == "\0user@example.com\0password123"
  end

  test "encodes with empty password" do
    encoded = Plain.encode("user@example.com", "")
    decoded = Base.decode64!(encoded)
    assert decoded == "\0user@example.com\0"
  end

  test "result is valid base64" do
    encoded = Plain.encode("user", "pass")
    assert {:ok, _} = Base.decode64(encoded)
  end

  test "encodes with special characters in password" do
    encoded = Plain.encode("user@example.com", "p@ss w0rd!")
    decoded = Base.decode64!(encoded)
    assert decoded == "\0user@example.com\0p@ss w0rd!"
  end
end
