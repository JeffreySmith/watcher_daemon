defmodule ServiceDiscovery.ServiceStarter do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.send_after(self(), {:start, opts}, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:start, opts}, state) do
    case Horde.DynamicSupervisor.start_child(
           ServiceDiscovery.HordeSupervisor,
           {ServiceDiscovery.Service, opts}
         ) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Failed to start ServiceDiscovery.Service: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
