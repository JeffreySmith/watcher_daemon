defmodule ServiceDiscovery.AuthStore do
  @moduledoc false

  require Logger
  @table :sd_auth

  def start do
    peers = Application.get_env(:service_discovery, :peers, [])
    connected_peers = Enum.filter(peers, &(Node.ping(&1) == :pong))

    case connected_peers do
      [] ->
        case :mnesia.create_schema([node()]) do
          :ok -> Logger.info("Mnesia schema created on #{node()}")
          {:error, {_, {:already_exists, _}}} -> :ok
          {:error, reason} -> Logger.warning("Failed to create Mnesia schema: #{inspect(reason)}")
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

  def ensure_table() do
    case :mnesia.add_table_copy(@table, node(), :disc_copies) do
      {:atomic, :ok} ->
        Logger.info("[AuthStore] table copied from cluster")

      {:aborted, {:already_exists, _}} ->
        Logger.info("[AuthStore] table already present on this node")

      {:aborted, {:no_exists, _}} ->
        case :mnesia.create_table(@table,
               attributes: [:username, :password_hash],
               type: :set,
               disc_copies: [node()]
             ) do
          {:atomic, :ok} ->
            Logger.info("[AuthStore] created new table on #{node()}")

          {:aborted, reason} ->
            Logger.error("[AuthStore] failed to create table: #{inspect(reason)}")
        end

      {:aborted, reason} ->
        Logger.error("[AuthStore] failed to add table copy: #{inspect(reason)}")
    end

    :mnesia.wait_for_tables([@table], 5_000)
    ensure_default_user()
  end

  defp ensure_default_user do
    case all_users() do
      [] ->
        password = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
        {:atomic, :ok} = add_user("admin", password)

        Logger.warning("""

        ============================================================================

        No users found. Default admin user created.
        Username: admin
        Password: #{password}
        This will not be shown again.
        ============================================================================

        """)

      _ ->
        :ok
    end
  end

  defp add_user(username, password) do
    hash = Argon2.hash_pwd_salt(password)

    :mnesia.transaction(fn ->
      :mnesia.write({@table, username, hash})
    end)
  end

  def create_user(username, password) do
    password_hash = Argon2.hash_pwd_salt(password)

    case :mnesia.transaction(fn -> :mnesia.read(@table, username) end) do
      {:atomic, []} ->
        Logger.info("Creating user #{username}")

        :mnesia.transaction(fn ->
          :mnesia.write({@table, username, password_hash})
        end)

      {:aborted, reason} ->
        Logger.info("Failed to read user #{username}: #{inspect(reason)}")

      {:atomic, :ok} ->
        Logger.info("User #{username} already exists")

      e ->
        Logger.warning("User #{username} default case???")
        Logger.warning("Error?? #{e}")
    end
  end

  def get_user(username) when is_binary(username) do
    case :mnesia.transaction(fn -> :mnesia.read(@table, username) end) do
      {:atomic, [{@table, ^username, password_hash}]} ->
        {:ok, password_hash}

      {:atomic, []} ->
        {:error, :not_found}

      {:aborted, reason} ->
        Logger.error("Failed to read user #{username}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def verify_user(username, plain_password)
      when is_binary(username) and is_binary(plain_password) do
    case get_user(username) do
      {:ok, password_hash} ->
        if Argon2.verify_pass(plain_password, password_hash) do
          {:ok, username}
        else
          {:error, :invalid_password}
        end

      {:error, :not_found} ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def change_password(username, new_plain_password) do
    new_hash = Argon2.hash_pwd_salt(new_plain_password)

    transaction = fn ->
      case :mnesia.read(@table, username) do
        [] ->
          {:error, :not_found}

        [{@table, ^username, _old_hash}] ->
          :mnesia.write({@table, username, new_hash})
          {:ok, :password_changed}
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, result} ->
        result

      {:aborted, reason} ->
        Logger.error("Failed to change password for #{username}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def delete_user(username) do
    transaction = fn ->
      case :mnesia.read(@table, username) do
        [] ->
          {:error, :not_found}

        [{@table, ^username, _}] ->
          :mnesia.delete({@table, username})
          {:ok, :user_deleted}
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, result} ->
        result

      {:aborted, reason} ->
        Logger.error("Failed to delete user #{username}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp all_users do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.all_keys(@table)
      end)

    result
  end

  def member?(user) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.read(@table, user)
      end)

    result != []
  end
end
