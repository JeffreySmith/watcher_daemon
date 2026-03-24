defmodule ServiceDiscovery.NodeWatcher do
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @reconnect_interval 30_000

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :connect_peers, 500)
    {:ok, %{disconnected: MapSet.new()}}
  end

  @impl true
  def handle_info(:connect_peers, state) do
    Application.get_env(:service_discovery, :peers, [])
    |> Enum.each(&connect/1)

    name = Application.get_env(:service_discovery, :service_name, "unnamed")
    seed = Application.get_env(:service_discovery, :candidates, [])
    ServiceDiscovery.CandidateStore.ensure_table(name, seed)

    ServiceDiscovery.AuthStore.ensure_table()

    {:noreply, state}
  end

  def handle_info({:nodeup, node, _}, state) do
    Logger.info("Node up: #{node}")
    sync_horde()
    {:noreply, %{state | disconnected: MapSet.delete(state.disconnected, node)}}
  end

  def handle_info({:nodedown, node, _}, state) do
    Logger.warning("Node down: #{node}")
    sync_horde()
    {:noreply, %{state | disconnected: MapSet.put(state.disconnected, node)}}
  end

  def handle_info({:reconnect, node}, state) do
    if MapSet.member?(state.disconnected, node) do
      case Node.connect(node) do
        true ->
          Logger.info("[NodeWatcher] reconnected to #{node}")
          {:noreply, state}

        _ ->
          Logger.warning(
            "[NodeWatcher] reconnect to #{node} failed, retrying in #{@reconnect_interval}ms"
          )

          Process.send_after(self(), {:reconnect, node}, @reconnect_interval)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp connect(peer) do
    case Node.connect(peer) do
      true -> Logger.info("[NodeWatcher] Successfully connected to #{peer}")
      false -> Logger.error("[NodeWatcher] Failed to connect to #{peer}")
      :ignored -> Logger.warning("[NodeWatcher] node not alive: #{peer}")
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
