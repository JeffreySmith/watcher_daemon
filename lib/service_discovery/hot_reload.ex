defmodule ServiceDiscovery.HotReload do
  @moduledoc false

  require Logger

  def reload do
    Mix.Task.run("compile")
    modules = get_app_modules()

    nodes = Node.list()

    for mod <- modules do
      case :code.get_object_code(mod) do
        {^mod, binary, filename} ->
          results = :rpc.multicall(nodes, :code, :load_binary, [mod, filename, binary])
          log_results(mod, nodes, results)

        :error ->
          Logger.error("[HotReload] failed to get object code for #{mod}")
      end
    end
  end

  def get_app_modules do
    {:ok, mods} = :application.get_key(:service_discovery, :modules)
    mods
  end

  defp log_results(mod, nodes, {results, bad_nodes}) do
    Enum.zip(nodes, results)
    |> Enum.each(fn {node, result} ->
      case result do
        {:module, _} ->
          Logger.info("[HotReload] #{mod} loaded on #{node}")

        {:error, reason} ->
          Logger.error("[HotReload] failed to load #{mod} on #{node}: #{inspect(reason)}")
      end
    end)

    if bad_nodes != [] do
      Logger.warning("[HotReload] failed to load #{mod} on nodes: #{inspect(bad_nodes)}")
    end
  end
end
