defmodule Plover.CommandTest do
  use ExUnit.Case, async: true

  alias Plover.Command

  test "creates a command with tag, name, and args" do
    cmd = %Command{tag: "A001", name: "SELECT", args: ["INBOX"]}
    assert cmd.tag == "A001"
    assert cmd.name == "SELECT"
    assert cmd.args == ["INBOX"]
  end

  test "defaults args to empty list" do
    cmd = %Command{tag: "A001", name: "NOOP"}
    assert cmd.args == []
  end
end
