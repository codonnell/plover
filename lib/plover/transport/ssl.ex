defmodule Plover.Transport.SSL do
  @moduledoc """
  SSL transport implementation for production IMAP connections.
  """

  @behaviour Plover.Transport

  @default_opts [
    active: false,
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    depth: 3
  ]

  @impl true
  def connect(host, port, opts) do
    ssl_opts = Keyword.merge(@default_opts, opts)
    :ssl.connect(String.to_charlist(host), port, ssl_opts)
  end

  @impl true
  def send(socket, data) do
    :ssl.send(socket, data)
  end

  @impl true
  def close(socket) do
    :ssl.close(socket)
  end

  @impl true
  def setopts(socket, opts) do
    :ssl.setopts(socket, opts)
  end

  @impl true
  def controlling_process(socket, pid) do
    :ssl.controlling_process(socket, pid)
  end

  @impl true
  def tag, do: :ssl
end
