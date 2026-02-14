defmodule Plover.Transport do
  @moduledoc """
  Behaviour for IMAP transport connections.

  Abstracts over SSL (production) and Mock (testing) transports.
  """

  @type socket :: any()
  @type option :: {:active, :once | false}

  @doc "Establishes a connection to the given host and port."
  @callback connect(String.t(), :inet.port_number(), keyword()) ::
              {:ok, socket()} | {:error, term()}

  @doc "Sends data over the connection."
  @callback send(socket(), iodata()) :: :ok | {:error, term()}

  @doc "Closes the connection."
  @callback close(socket()) :: :ok | {:error, term()}

  @doc "Sets socket options (e.g., `active: :once`)."
  @callback setopts(socket(), [option()]) :: :ok | {:error, term()}

  @doc "Transfers socket ownership to another process."
  @callback controlling_process(socket(), pid()) :: :ok | {:error, term()}

  @doc """
  Returns the message tag used for active-mode delivery.

  SSL uses `:ssl`, Mock uses `:mock_ssl`.
  """
  @callback tag() :: atom()
end
