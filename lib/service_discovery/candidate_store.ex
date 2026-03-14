defmodule ServiceDiscovery.CandidateStore do
  require Logger

  @table :sd_candidates
  @doc """
  Initialize Mnesia on this node
  """
  def start() do
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

  def ensure_table(seed_candidates \\ []) do
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
            # :key is {host, port}
            attributes: [:key, :ignored],
            type: :set,
            disc_copies: [node()]
          )

        Logger.info("[CandidateStore] created new table on #{node()}")
        seed(seed_candidates)

      {:aborted, reason} ->
        Logger.error("Failed to create table: #{inspect(reason)}")
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

  @spec all() :: [{String.t(), pos_integer()}]
  def all do
    :mnesia.dirty_all_keys(@table)
    |> Enum.map(fn {host, port} -> {host, port} end)
  end

  @spec get_one() :: {String.t(), pos_integer()} | nil
  def get_one do
    case Enum.shuffle(all()) do
      [] -> nil
      [{host, port} | _] -> {host, port}
    end
  end

  def get_one_available do
    all()
    |> Enum.shuffle()
    |> Enum.find(fn {host, port} -> ServiceDiscovery.Service.tcp_open?(host, port) end)
  end

  @spec add(String.t(), pos_integer()) :: :ok
  def add(host, port) do
    :mnesia.dirty_write({@table, {host, port}, nil})
    Logger.info("[CandidateStore] added #{host}:#{port}")
    :ok
  end

  @spec remove(String.t(), pos_integer()) :: :ok
  def remove(host, port) do
    :mnesia.dirty_delete({@table, {host, port}})
    Logger.info("[CandidateStore] removed #{host}:#{port}")
    :ok
  end

  @spec member?(String.t(), pos_integer()) :: boolean()
  def member?(host, port) do
    :mnesia.dirty_read(@table, {host, port}) != []
  end

  defp seed([]), do: :ok

  defp seed(candidates) do
    Logger.info("[CandidateStore] seeding #{length(candidates)} candidates")
    Enum.each(candidates, fn {h, p} -> add(h, p) end)
  end
end
