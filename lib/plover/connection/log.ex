defmodule Plover.Connection.Log do
  @moduledoc false

  require Logger

  @default_truncate_limit 512

  # --- Public logging functions ---

  def command_sent(tag, name, args) do
    Logger.debug(fn ->
      {"C: #{tag} #{name} #{format_args(redact_args(name, args))}",
       imap_event: :command_sent, imap_tag: tag, imap_command: name}
    end)
  end

  def data_received(data) do
    Logger.debug(fn ->
      {"S: #{truncate(data)}", imap_event: :data_received}
    end)
  end

  def connected(host, port) do
    Logger.info(fn ->
      {"Connected to #{host}:#{port}", imap_event: :connected}
    end)
  end

  def greeting_received(conn_state) do
    Logger.info(fn ->
      {"Greeting received, state: #{conn_state}", imap_event: :greeting_received}
    end)
  end

  def disconnected(reason) do
    Logger.info(fn ->
      {"Disconnected: #{inspect(reason)}", imap_event: :disconnected}
    end)
  end

  def ssl_error(reason) do
    Logger.warning(fn ->
      {"SSL error: #{inspect(reason)}", imap_event: :ssl_error}
    end)
  end

  def greeting_timeout do
    Logger.warning(fn ->
      {"Timed out waiting for server greeting", imap_event: :greeting_timeout}
    end)
  end

  def command_completed(tag, command, :ok) do
    Logger.debug(fn ->
      {"#{tag} #{command} completed OK",
       imap_event: :command_completed, imap_tag: tag, imap_command: command}
    end)
  end

  def command_completed(tag, command, status) do
    Logger.warning(fn ->
      {"#{tag} #{command} completed #{String.upcase(to_string(status))}",
       imap_event: :command_completed, imap_tag: tag, imap_command: command}
    end)
  end

  def state_transition(command, from, to) do
    Logger.info(fn ->
      {"State transition #{from} -> #{to} (#{command})",
       imap_event: :state_transition, imap_command: command}
    end)
  end

  def literal_sent(tag, size) do
    Logger.debug(fn ->
      {"#{tag} literal sent (#{size} bytes)",
       imap_event: :literal_sent, imap_tag: tag}
    end)
  end

  def idle_started(tag) do
    Logger.debug(fn ->
      {"#{tag} IDLE started", imap_event: :idle_started, imap_tag: tag, imap_command: "IDLE"}
    end)
  end

  def idle_done_sent do
    Logger.debug(fn ->
      {"DONE sent (exiting IDLE)", imap_event: :idle_done, imap_command: "IDLE"}
    end)
  end

  def parse_error(reason) do
    Logger.warning(fn ->
      {"Failed to parse response: #{inspect(reason)}", imap_event: :parse_error}
    end)
  end

  # --- Private helpers ---

  @doc false
  def redact_args("LOGIN", [user | _rest]) do
    [user, "[REDACTED]"]
  end

  def redact_args("AUTHENTICATE", [mechanism | _rest]) do
    [mechanism, "[REDACTED]"]
  end

  def redact_args(_name, args), do: args

  @doc false
  def truncate(data) when is_binary(data) do
    case Application.get_env(:plover, :log_truncate_limit, @default_truncate_limit) do
      :infinity -> data
      limit when byte_size(data) <= limit -> data

      limit ->
        truncated = binary_part(data, 0, limit)
        remaining = byte_size(data) - limit
        "#{truncated}... (#{remaining} more bytes)"
    end
  end

  def truncate(data), do: truncate(IO.iodata_to_binary(data))

  defp format_args([]), do: ""

  defp format_args(args) do
    args
    |> Enum.map(&format_arg/1)
    |> Enum.join(" ")
  end

  defp format_arg({:raw, value}), do: value
  defp format_arg({:literal, data}), do: "{#{byte_size(data)} literal}"
  defp format_arg(arg) when is_binary(arg), do: arg
  defp format_arg(arg), do: inspect(arg)
end
