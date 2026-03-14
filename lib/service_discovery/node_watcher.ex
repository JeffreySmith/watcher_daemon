defmodule ServiceDiscovery.NodeWatcher do
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :connect_peers, 500)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:connect_peers, state) do
    Application.get_env(:service_discovery, :peers, [])
    |> Enum.each(&connect/1)

    seed = Application.get_env(:service_discovery, :candidates, [])
    ServiceDiscovery.CandidateStore.ensure_table(seed)

    {:noreply, state}
  end

  def handle_info({:nodeup, node, _}, state) do
    Logger.info("Node up: #{node}")
    sync_horde()
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _}, state) do
    Logger.warning("Node down: #{node}")
    sync_horde()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp connect(peer) do
    case Node.connect(peer) do
      true -> Logger.info("Successfully connected to #{peer}")
      false -> Logger.error("Failed to connect to #{peer}")
      :ignored -> Logger.warning("Connection to #{peer} ignored (already connected?)")
    end
  end

  defp sync_horde do
    nodes = [node() | Node.list()]

    Horde.Cluster.set_members(
      ServiceDiscovery.Registry,
      Enum.map(nodes, &{ServiceDiscovery.Registry, &1})
    )

    Horde.Cluster.set_members(
      ServiceDiscovery.HordeSupervisor,
      Enum.map(nodes, &{ServiceDiscovery.HordeSupervisor, &1})
    )
  end
end
