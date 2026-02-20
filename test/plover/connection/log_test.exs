defmodule Plover.Connection.LogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Plover.Connection.Log

  describe "redact_args/2" do
    test "redacts LOGIN password" do
      assert Log.redact_args("LOGIN", ["user@example.com", "secret123"]) ==
               ["user@example.com", "[REDACTED]"]
    end

    test "redacts AUTHENTICATE credentials" do
      assert Log.redact_args("AUTHENTICATE", ["PLAIN", "base64encoded"]) ==
               ["PLAIN", "[REDACTED]"]
    end

    test "does not redact other commands" do
      args = ["INBOX"]
      assert Log.redact_args("SELECT", args) == args
    end

    test "does not redact FETCH args" do
      args = ["1:5", {:raw, "(FLAGS UID)"}]
      assert Log.redact_args("FETCH", args) == args
    end
  end

  describe "truncate/1" do
    setup do
      previous = Application.get_env(:plover, :log_truncate_limit)
      on_exit(fn -> Application.put_env(:plover, :log_truncate_limit, previous || 512) end)
      Application.delete_env(:plover, :log_truncate_limit)
      :ok
    end

    test "returns short strings unchanged" do
      assert Log.truncate("short") == "short"
    end

    test "returns strings at default limit unchanged" do
      data = String.duplicate("a", 512)
      assert Log.truncate(data) == data
    end

    test "truncates long strings with byte count at default limit" do
      data = String.duplicate("a", 600)
      result = Log.truncate(data)
      assert String.starts_with?(result, String.duplicate("a", 512))
      assert String.contains?(result, "88 more bytes")
    end

    test "respects custom truncate limit" do
      Application.put_env(:plover, :log_truncate_limit, 10)
      data = String.duplicate("a", 20)
      result = Log.truncate(data)
      assert result == "aaaaaaaaaa... (10 more bytes)"
    end

    test "disables truncation with :infinity" do
      Application.put_env(:plover, :log_truncate_limit, :infinity)
      data = String.duplicate("a", 2000)
      assert Log.truncate(data) == data
    end
  end

  describe "command_sent/3 with CaptureLog" do
    test "does not leak LOGIN password" do
      log =
        capture_log(fn ->
          Log.command_sent("A0001", "LOGIN", ["user@example.com", "secret123"])
        end)

      assert log =~ "A0001 LOGIN"
      assert log =~ "user@example.com"
      assert log =~ "[REDACTED]"
      refute log =~ "secret123"
    end

    test "does not leak AUTHENTICATE credentials" do
      log =
        capture_log(fn ->
          Log.command_sent("A0002", "AUTHENTICATE", ["PLAIN", "AGpvaG4AcGFzc3dvcmQ="])
        end)

      assert log =~ "A0002 AUTHENTICATE"
      assert log =~ "PLAIN"
      assert log =~ "[REDACTED]"
      refute log =~ "AGpvaG4AcGFzc3dvcmQ="
    end

    test "logs normal commands fully" do
      log =
        capture_log(fn ->
          Log.command_sent("A0003", "SELECT", ["INBOX"])
        end)

      assert log =~ "A0003 SELECT INBOX"
    end
  end

  describe "data_received/1" do
    test "truncates large server data" do
      data = "* OK " <> String.duplicate("x", 600)

      log =
        capture_log(fn ->
          Log.data_received(data)
        end)

      assert log =~ "S: * OK"
      assert log =~ "more bytes"
    end
  end
end
