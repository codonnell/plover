defmodule Plover.Connection.State do
  @moduledoc false

  defstruct [
    :transport,
    :socket,
    conn_state: :not_authenticated,
    tag_counter: 1,
    buffer: "",
    pending: %{},
    idle_state: nil,
    capabilities: MapSet.new(),
    selected_mailbox: nil,
    mailbox_info: nil,
    on_unsolicited_response: nil
  ]

  @type t :: %__MODULE__{
          transport: module(),
          socket: any(),
          conn_state: :not_authenticated | :authenticated | :selected | :logout,
          tag_counter: pos_integer(),
          buffer: binary(),
          pending: map(),
          idle_state: nil | map(),
          capabilities: MapSet.t(),
          selected_mailbox: nil | String.t(),
          mailbox_info: nil | map(),
          on_unsolicited_response: nil | (Plover.Types.untagged_response() -> any())
        }

  def next_tag(%__MODULE__{tag_counter: n} = state) do
    tag = "A" <> String.pad_leading(Integer.to_string(n), 4, "0")
    {tag, %{state | tag_counter: n + 1}}
  end
end
