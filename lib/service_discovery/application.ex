defmodule ServiceDiscovery.Application do
  @moduledoc false

  use Application
  require Logger

  def start(_type, _args) do
    ServiceDiscovery.CandidateStore.start()
    ServiceDiscovery.AuthStore.start()
    port = Application.get_env(:service_discovery, :http_port, 4000)
    password = Application.get_env(:service_discovery, :password, "")

    pass =
      case password do
        "" ->
          ""

        pass ->
          Argon2.hash_pwd_salt(pass)
      end

    Logger.info("Using password hash: #{pass}")

    children = [
      {Horde.Registry, [name: ServiceDiscovery.Registry, keys: :unique]},
      {Horde.DynamicSupervisor,
       [name: ServiceDiscovery.HordeSupervisor, strategy: :one_for_one, members: :auto]},
      ServiceDiscovery.NodeWatcher,
      ServiceDiscovery.ServiceStarter,
      {Plug.Cowboy, scheme: :http, plug: ServiceDiscovery.HTTP, options: [port: port]}
    ]

    Logger.info("Servicediscovery starting on #{node()}")

    Supervisor.start_link(children, strategy: :one_for_one, name: ServiceDiscovery.Supervisor)
  end
end
