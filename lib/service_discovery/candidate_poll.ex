defmodule ServiceDiscovery.CandidatePoller do
  use GenServer
  require Logger

  @ets_table :candidate_cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    poll_interval = Keyword.get(opts, :poll_interval, 10_000)
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    probe_timout = Keyword.get(opts, :probe_timeout, 500)

    ets =
      :ets.new(@ets_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    Logger.info("[CandidatePoller] created ETS table #{inspect(ets)}")

    state = %{
      poll_interval: poll_interval,
      max_concurrency: max_concurrency,
      probe_timeout: probe_timout
    }

    Process.send_after(self(), :poll, 500)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_services(state)
    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    poll_services(state)
    {:noreply, state}
  end

  defp poll_services(%{max_concurrency: max_c, probe_timeout: timeout} = _state) do
    candidates = ServiceDiscovery.CandidateStore.all()
    now = DateTime.utc_now()

    expected_keys =
      Enum.map(candidates, fn %ServiceDiscovery.Candidate{service_name: sn, host: h, port: p} ->
        {sn, h, p}
      end)

    candidates
    |> Task.async_stream(
      fn %ServiceDiscovery.Candidate{service_name: sn, host: h, port: p} = _c ->
        key = {sn, h, p}

        up =
          try do
            ServiceDiscovery.Service.tcp_open?(h, p, timeout)
          rescue
            e ->
              Logger.debug("[CandidatePoller] error probing #{inspect(key)} - #{inspect(e)}")
              false
          catch
            :exit, reason ->
              Logger.debug("[CandidatePoller] exit probing #{inspect(key)} - #{inspect(reason)}")

              false
          end

        value = %{
          service_name: sn,
          host: h,
          port: p,
          up: up,
          last_checked: now
        }

        :ets.insert(@ets_table, {key, value})
      end,
      max_concurrency: max_c,
      timeout: timeout + 100,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, _key} ->
        :ok

      {:exit, reason} ->
        Logger.debug("[CandidatePoller] probe exited: #{inspect(reason)}")

      {:error, reason} ->
        Logger.debug("[CandidatePoller] error checking candidate: #{inspect(reason)}")
    end)

    cleanup_stale_entries(expected_keys)
  end

  defp cleanup_stale_entries(keys) do
    expected_set = MapSet.new(keys)

    :ets.tab2list(@ets_table)
    |> Enum.each(fn {key, _value} ->
      unless MapSet.member?(expected_set, key) do
        :ets.delete(@ets_table, key)
      end
    end)
  end

  # Force polling now
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  def lookup_by_service(service_name) when is_binary(service_name) do
    match_spec = [
      {
        {{service_name, :"$1", :"$2"}, :"$3"},
        [],
        [:"$3"]
      }
    ]

    :ets.select(@ets_table, match_spec)
  rescue
    ArgumentError -> []
  end

  def lookup_by_host(host) when is_binary(host) do
    match_spec = [
      {
        {{:"$1", host, :"$2"}, :"$3"},
        [],
        [:"$3"]
      }
    ]

    :ets.select(@ets_table, match_spec)
  rescue
    ArgumentError -> []
  end
end
