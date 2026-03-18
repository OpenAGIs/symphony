defmodule SymphonyElixir.Linear.MetadataCache do
  @moduledoc """
  A simple GenServer to cache static Linear metadata (viewer IDs, state IDs).
  """

  use GenServer
  require Logger

  defstruct viewer_id: nil, states: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_viewer_id() :: String.t() | nil
  def get_viewer_id do
    GenServer.call(__MODULE__, :get_viewer_id)
  end

  @spec put_viewer_id(String.t()) :: :ok
  def put_viewer_id(id) when is_binary(id) do
    GenServer.cast(__MODULE__, {:put_viewer_id, id})
  end

  @spec get_state_id(String.t()) :: String.t() | nil
  def get_state_id(state_name) when is_binary(state_name) do
    GenServer.call(__MODULE__, {:get_state_id, state_name})
  end

  @spec put_state_id(String.t(), String.t()) :: :ok
  def put_state_id(state_name, state_id) when is_binary(state_name) and is_binary(state_id) do
    GenServer.cast(__MODULE__, {:put_state_id, state_name, state_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:get_viewer_id, _from, state) do
    {:reply, state.viewer_id, state}
  end

  def handle_call({:get_state_id, state_name}, _from, state) do
    {:reply, Map.get(state.states, state_name), state}
  end

  @impl true
  def handle_cast({:put_viewer_id, id}, state) do
    {:noreply, %{state | viewer_id: id}}
  end

  def handle_cast({:put_state_id, state_name, state_id}, state) do
    {:noreply, %{state | states: Map.put(state.states, state_name, state_id)}}
  end
end
