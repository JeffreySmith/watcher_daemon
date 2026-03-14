defmodule ServiceDiscovery.Service do
  use GenServer
  require Logger

  @probe_timeout Application.compile_env(:service_discovery, :discovery_timeout_ms, 5_000)
  @via {:via, Horde.Registry, {ServiceDiscovery.Registry, :service}}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.get(opts, :candidates, []), name: @via)
  end

  def first_available, do: GenServer.call(@via, :first_available)
  def candidates, do: ServiceDiscovery.CandidateStore.all()

  def add_candidate(h, p), do: ServiceDiscovery.CandidateStore.add(h, p)
  def remove_candidate(h, p), do: ServiceDiscovery.CandidateStore.remove(h, p)

  @impl true
  def init(candidates) do
    Logger.info("[Service] started on #{node()}, candidates=#{inspect(candidates)}")
    {:ok, MapSet.new(candidates)}
  end

  @impl true
  def handle_call(:first_available, _from, candidates) do
    result =
      candidates
      |> MapSet.to_list()
      |> Enum.shuffle()
      |> Enum.find_value({:error, :none_available}, fn {h, p} = c ->
        if tcp_open?(h, p), do: {:ok, c}, else: nil
      end)

    {:reply, result, candidates}
  end

  def tcp_open?(host, port) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false],
           @probe_timeout
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
