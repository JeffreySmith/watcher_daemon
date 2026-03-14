defmodule ServiceDiscovery.HTTP do
  use Plug.Router
  require Logger

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "Service Discovery API")
  end

  get "/candidate" do
    case ServiceDiscovery.CandidateStore.get_one_available() do
      {host, port} ->
        send_resp(conn, 200, Jason.encode!(%{host: host, port: port}))

      nil ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))
    end
  end

  get "/candidates" do
    candidates =
      ServiceDiscovery.Service.candidates()
      |> Enum.map(fn {h, p} ->
        %{host: h, port: p, up: ServiceDiscovery.Service.tcp_open?(h, p)}
      end)

    case candidates do
      [] ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))

      _ ->
        send_resp(conn, 200, Jason.encode!(candidates))
    end
  end

  get "/service/:name" do
    send_resp(conn, 200, "Service is: #{name}")
  end

  get "/service/:name/candidate" do
    send_resp(conn, 200, "If #{name} were handled, you would get json pointing to a service")
  end

  get _ do
    Logger.info("Request path is: #{conn.request_path}")
    send_resp(conn, 404, Jason.encode!(%{error: "No such endpoint"}))
  end
end
