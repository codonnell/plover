defmodule Plover.Transport.SSL do
  @moduledoc """
  SSL transport implementation for production IMAP connections.
  """

  @behaviour Plover.Transport

  @impl true
  def connect(host, port, opts) do
    charlist_host = String.to_charlist(host)

    default_opts = [
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: charlist_host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    ssl_opts = Keyword.merge(default_opts, opts)
    :ssl.connect(charlist_host, port, ssl_opts)
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
