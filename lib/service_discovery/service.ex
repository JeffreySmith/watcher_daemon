defmodule ServiceDiscovery.Service do
  use GenServer
  require Logger
  @default_probe_timeout 5_000

  @probe_timeout @default_probe_timeout
  @via {:via, Horde.Registry, {ServiceDiscovery.Registry, :service}}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.get(opts, :candidates, []), name: @via)
  end

  def first_available, do: GenServer.call(@via, :first_available)
  def candidates, do: ServiceDiscovery.CandidateStore.cached_all()

  def add(s, h, p),
    do:
      ServiceDiscovery.CandidateStore.add(%ServiceDiscovery.Candidate{
        service_name: s,
        host: h,
        port: p
      })

  def remove(s, h, p),
    do:
      ServiceDiscovery.CandidateStore.remove(%ServiceDiscovery.Candidate{
        service_name: s,
        host: h,
        port: p
      })

  @impl true
  def init(candidates) do
    Logger.info("[Service] started on #{node()}, candidates=#{inspect(candidates)}")
    candidates = ServiceDiscovery.CandidateStore.all() |> MapSet.new()
    {:ok, candidates}
  end

  @impl true
  def handle_call(:first_available, _from, candidates) do
    cache_pick =
      case :ets.info(:candidate_cache) do
        :undefined ->
          Logger.info("[Service] ETS cache not available, falling back to direct checks")
          nil

        _info ->
          Logger.info("[Service] checking ETS cache for available candidates")

          :ets.tab2list(:candidate_cache)
          |> Enum.map(fn
            {{_sn, _host, _port}, %{} = value_map} ->
              value_map

            {{_sn, _host, _port}, %ServiceDiscovery.Candidate{} = cand} ->
              %{
                service_name: cand.service_name,
                host: cand.host,
                port: cand.port,
                up: nil,
                last_checked: nil
              }

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn m -> Map.get(m, :up) == true end)
          |> Enum.shuffle()
          |> List.first()
      end

    case cache_pick do
      %{} = picked ->
        cand = %ServiceDiscovery.Candidate{
          service_name: Map.get(picked, :service_name) || Map.get(picked, "service_name"),
          host: Map.get(picked, :host) || Map.get(picked, "host"),
          port: Map.get(picked, :port) || Map.get(picked, "port")
        }

        {:reply, {:ok, cand}, candidates}

      nil ->
        result =
          candidates
          |> MapSet.to_list()
          |> Enum.shuffle()
          |> Enum.find_value({:error, :none_available}, fn %ServiceDiscovery.Candidate{
                                                             service_name: _sn,
                                                             host: h,
                                                             port: p
                                                           } = c ->
            if tcp_open?(h, p), do: {:ok, c}, else: nil
          end)

        {:reply, result, candidates}
    end
  end

  def tcp_open?(host, port, timeout \\ 500) do
    # IO.inspect({host, port}, label: "[Service] probing #{host}:#{port}")

    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false],
           timeout
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end
end
