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
    IO.inspect(candidates, label: "[Service] current candidates ")

    result =
      candidates
      |> MapSet.to_list()
      |> Enum.shuffle()
      |> IO.inspect(label: "[Service] checking candidates")
      |> Enum.find_value({:error, :none_available}, fn %ServiceDiscovery.Candidate{
                                                         service_name: _sn,
                                                         host: h,
                                                         port: p
                                                       } = c ->
        if tcp_open?(h, p), do: {:ok, c}, else: nil
      end)

    {:reply, result, candidates}
  end

  def tcp_open?(host, port) do
    IO.inspect({host, port}, label: "[Service] probing #{host}:#{port}")

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
