defmodule Plover.Transport.SSL do
  @moduledoc """
  SSL transport implementation for production IMAP connections.
  """

  @behaviour Plover.Transport

  @impl true
  def connect(host, port, opts) do
    # Erlang's :ssl module requires hostnames as charlists (also used for SNI)
    charlist_host = if is_binary(host), do: String.to_charlist(host), else: host

    default_opts = [
      active: false,
      mode: :binary,
      packet: :line,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: charlist_host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    ssl_opts = default_opts ++ List.wrap(opts)
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
