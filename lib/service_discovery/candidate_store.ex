defmodule ServiceDiscovery.Candidate do
  @derive Jason.Encoder
  defstruct [:service_name, :host, :port]

  @type t :: %__MODULE__{
          service_name: String.t(),
          host: String.t(),
          port: pos_integer()
        }
end

defmodule ServiceDiscovery.CandidateStore do
  require Logger
  require ServiceDiscovery.Candidate

  @table :sd_candidates
  # The cache for which services are currently up. Only in memory
  @ets_table :candidate_cache
  @doc """
  Initialize Mnesia on this node
  """
  def start() do
    # We stop this in order to enable local file storage
    :mnesia.stop()

    peers = Application.get_env(:service_discovery, :peers, [])
    connected_peers = Enum.filter(peers, &(Node.ping(&1) == :pong))

    case connected_peers do
      [] ->
        case :mnesia.create_schema([node()]) do
          :ok -> Logger.info("Mnesia schema created on #{node()}")
          {:error, {_, {:already_exists, _}}} -> :ok
          {:error, reason} -> Logger.error("Failed to create Mnesia schema: #{inspect(reason)}")
        end

        :mnesia.start()

      peers ->
        Logger.info("[CandidateStore] Joining schema from #{inspect(peers)}")
        :mnesia.start()

        case :mnesia.change_config(:extra_db_nodes, peers) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "[CandidateStore] schema copy failed: #{inspect(reason)}"
        end

        case :mnesia.change_table_copy_type(:schema, node(), :disc_copies) do
          {:atomic, :ok} -> Logger.info("[CandidateStore] schema upgraded to disc_copies")
          {:aborted, {:already_exists, _, _, _}} -> :ok
          {:aborted, reason} -> raise "[CandidateStore] schema copy failed: #{inspect(reason)}"
        end
    end
  end

  def ensure_table(service_name \\ "", seed_candidates \\ []) do
    extra = :mnesia.change_config(:extra_db_nodes, Node.list())

    Logger.info("[CandidateStore] change_config result=#{inspect(extra)}")

    info = :mnesia.info()
    Logger.info("[CandidateStore] mnesia info=#{inspect(info)}")

    result = :mnesia.add_table_copy(@table, node(), :disc_copies)
    Logger.info("[CandidateStore] add_table_copy result=#{inspect(result)}")

    case result do
      {:atomic, :ok} ->
        Logger.info("[CandidateStore] table copied from cluster")

      {:aborted, {:already_exists, _}} ->
        Logger.info("[CandidateStore] table already present on this node")

      {:aborted, {:no_exists, _}} ->
        {:atomic, :ok} =
          :mnesia.create_table(@table,
            # :key is {service_name, host, port}
            attributes: [:key, :candidate],
            type: :set,
            disc_copies: [node()]
          )

        Logger.info("[CandidateStore] created new table on #{node()}")
        seed(service_name, seed_candidates)

      {:aborted, reason} ->
        Logger.warning("Failed to create table: #{inspect(reason)}")
    end

    :mnesia.wait_for_tables([@table], 10_000)
  end

  @doc """
  Replicate data to this node once it has connected to some other node in the cluster
  """
  def replicate_to_local do
    case :mnesia.add_table_copy(@table, node(), :disc_copies) do
      {:atomic, :ok} -> Logger.info("[CandidateStore] table replicated to #{node()}")
      {:aborted, {:already_exists, _, _}} -> :ok
      {:aborted, reason} -> Logger.error("Failed to replicate table: #{inspect(reason)}")
    end
  end

  @spec all() :: [ServiceDiscovery.Candidate.t()]
  def all do
    :mnesia.dirty_match_object({@table, :_, :_})
    |> Enum.map(fn {@table, _key, candidate} -> candidate end)
  end

  @spec cached_all() :: [map()]
  def cached_all do
    case :ets.info(@ets_table) do
      # No cache exists
      :undefined ->
        Logger.warning("[CandidateStore] cache not found, falling back to Mnesia")

        all()
        |> Enum.map(fn %ServiceDiscovery.Candidate{service_name: sn, host: h, port: p} ->
          %{
            service_name: sn,
            host: h,
            port: p,
            up: nil,
            last_checked: nil
          }
        end)

      _ ->
        :ets.tab2list(:candidate_cache)
        |> Enum.map(fn {{_sn, _host, _port}, %{} = value_map} ->
          %{
            service_name: Map.get(value_map, :service_name),
            host: Map.get(value_map, :host),
            port: Map.get(value_map, :port),
            up: Map.get(value_map, :up),
            last_checked: Map.get(value_map, :last_checked)
          }
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  @spec get_one() :: {String.t(), pos_integer()} | nil
  def get_one do
    case Enum.shuffle(cached_all()) do
      [] -> nil
      [{service_name, host, port} | _] -> {service_name, host, port}
    end
  end

  def get_all_available do
    cached_all()
    |> Enum.filter(fn m -> match?(%{up: true}, m) end)
  end

  def get_one_available do
    cached_all()
    |> Enum.shuffle()
    |> IO.inspect(label: "[CandidateStore] shuffled candidates")
    |> Enum.find(fn
      %{up: true} -> true
      _ -> false
    end)
  end

  # @spec add(String.t(), String.t(), pos_integer()) :: :ok
  def add(%ServiceDiscovery.Candidate{service_name: sn, host: host, port: port} = candidate) do
    :mnesia.dirty_write({@table, {sn, host, port}, candidate})
    Logger.info("[CandidateStore] added #{host}:#{port} for #{sn}")
    :ok
  end

  #  @spec remove(String.t(), String.t(), pos_integer()) :: :ok
  def remove(%ServiceDiscovery.Candidate{service_name: sn, host: host, port: port}) do
    :mnesia.dirty_delete({@table, {sn, host, port}})
    Logger.info("[CandidateStore] removed #{host}:#{port} for #{sn}")
    :ok
  end

  @spec member?(String.t(), String.t(), pos_integer()) :: boolean()
  def member?(service_name, host, port) do
    :mnesia.dirty_read(@table, {service_name, host, port}) != []
  end

  defp seed(_, []), do: :ok

  defp seed(service_name, candidates) do
    Logger.info("[CandidateStore] seeding #{length(candidates)} candidates for '#{service_name}'")

    Enum.each(candidates, fn %ServiceDiscovery.Candidate{service_name: sn, host: host, port: port} ->
      add(%ServiceDiscovery.Candidate{service_name: sn, host: host, port: port})
    end)
  end
end
