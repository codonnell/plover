defmodule Plover.Integration.BatchFetchLiveTest do
  use ExUnit.Case

  alias Plover.BodyStructure, as: BS

  @moduletag :live

  @host System.get_env("IMAP_HOST") || "missing"
  @user System.get_env("IMAP_USER") || "missing"
  @pass System.get_env("IMAP_PASS") || "missing"

  defp connect_and_select(mailbox \\ "INBOX") do
    {:ok, conn} = Plover.connect(@host)
    {:ok, _} = Plover.login(conn, @user, @pass)
    {:ok, _} = Plover.select(conn, mailbox)
    conn
  end

  describe "fetch_parts_batch/3 against live server" do
    test "downloads 200 email bodies" do
      conn = connect_and_select()

      # Find 200 UIDs via UID FETCH (works with both IMAP4rev1 and rev2)
      {:ok, all_messages} = Plover.uid_fetch(conn, "1:*", [:uid])
      uids = Enum.map(all_messages, fn msg -> msg.attrs.uid end) |> Enum.sort()
      assert length(uids) >= 200, "need at least 200 emails, got #{length(uids)}"
      uids = Enum.take(uids, 200)

      # Fetch body structures for all 200
      uid_set = Enum.join(uids, ",")
      {:ok, messages} = Plover.uid_fetch(conn, uid_set, [:body_structure, :uid])
      assert length(messages) == 200

      # Build {uid, parts} list — pick text/plain or text/html or first text/*
      parts_by_uid =
        for msg <- messages, parts = find_text_parts(msg.attrs.body_structure), parts != [] do
          {to_string(msg.attrs.uid), parts}
        end

      assert length(parts_by_uid) > 0, "no messages with text parts found"

      # Batch fetch with default concurrency
      {:ok, results} = Plover.fetch_parts_batch(conn, parts_by_uid)

      assert map_size(results) == length(parts_by_uid)

      # Count successes vs failures. Most should decode successfully.
      {successes, failures} =
        Enum.split_with(results, fn {_uid, result} -> match?({:ok, _}, result) end)

      success_count = length(successes)
      failure_count = length(failures)

      # Log error distribution for debugging
      error_reasons =
        failures
        |> Enum.map(fn {_uid, {:error, reason}} -> inspect(reason) end)
        |> Enum.frequencies()

      assert success_count >= length(parts_by_uid) * 0.9,
             "expected at least 90% success, got #{success_count}/#{length(parts_by_uid)} " <>
               "(#{failure_count} failures: #{inspect(error_reasons)})"

      # Verify successful results have valid decoded content
      for {uid, {:ok, decoded_parts}} <- successes do
        assert is_list(decoded_parts), "expected list for UID #{uid}"

        for {section, body} <- decoded_parts do
          assert is_binary(body), "expected binary for UID #{uid} section #{section}"
        end
      end

      # Verify failures are tagged with reasons
      for {uid, {:error, reason}} <- failures do
        assert reason != nil, "expected error reason for UID #{uid}"
      end

      {:ok, _} = Plover.logout(conn)
    end

  end

  defp find_text_parts(bs) do
    case BS.find_parts(bs, "text/plain") do
      [_ | _] = parts -> parts
      [] ->
        case BS.find_parts(bs, "text/html") do
          [_ | _] = parts -> parts
          [] ->
            case BS.find_parts(bs, "text/*") do
              [first | _] -> [first]
              [] -> []
            end
        end
    end
  end
end
