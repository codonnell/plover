defmodule Plover.Transport do
  @moduledoc """
  Behaviour for IMAP transport connections.

  Abstracts over SSL (production) and Mock (testing) transports.
  """

  @type socket :: any()
  @type option :: {:active, :once | false}

  @callback connect(String.t(), :inet.port_number(), keyword()) ::
              {:ok, socket()} | {:error, term()}

  @callback send(socket(), iodata()) :: :ok | {:error, term()}

  @callback close(socket()) :: :ok | {:error, term()}

  @callback setopts(socket(), [option()]) :: :ok | {:error, term()}

  @callback controlling_process(socket(), pid()) :: :ok | {:error, term()}

  @doc """
  The message tag used by this transport for active-mode delivery.
  SSL uses :ssl, Mock uses :mock_ssl.
  """
  @callback tag() :: atom()
end
