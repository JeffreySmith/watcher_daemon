defmodule ServiceDiscovery.HTTP do
  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "Service Discovery API")
  end

  get "/candidate" do
    case ServiceDiscovery.CandidateStore.get_one_available() do
      %ServiceDiscovery.Candidate{service_name: sn, host: h, port: p} ->
        send_resp(conn, 200, Jason.encode!(%{service: sn, host: h, port: p}))

      nil ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))
    end
  end

  get "/candidates" do
    candidates =
      ServiceDiscovery.Service.candidates()
      |> Enum.map(fn %ServiceDiscovery.Candidate{service_name: sn, host: h, port: p} ->
        %{service_name: sn, host: h, port: p, up: ServiceDiscovery.Service.tcp_open?(h, p)}
      end)

    case candidates do
      [] ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))

      _ ->
        send_resp(conn, 200, Jason.encode!(candidates))
    end
  end

  get "/service/:name" do
    out = ServiceDiscovery.Service.first_available()
    IO.inspect(out, label: "[HTTP] first available for '#{name}'")

    case out do
      {:ok, %ServiceDiscovery.Candidate{service_name: ^name, host: host, port: port}} ->
        send_resp(conn, 200, Jason.encode!(%{service_name: name, host: host, port: port}))

      {:ok, _} ->
        send_resp(
          conn,
          503,
          Jason.encode!(%{error: "No candidates available for service '#{name}'"})
        )

      {:error, :none_available} ->
        send_resp(
          conn,
          503,
          Jason.encode!(%{error: "No candidates available for service '#{name}'"})
        )
    end
  end

  get "/service/:name/candidates" do
    IO.inspect(name, label: "[HTTP] fetching candidates for '#{name}'")

    candidates =
      ServiceDiscovery.Service.candidates()
      |> Enum.filter(fn %ServiceDiscovery.Candidate{service_name: sn} -> sn == name end)

    case candidates do
      [] ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))

      _ ->
        send_resp(conn, 200, Jason.encode!(candidates))
    end
  end

  post "/auth" do
    case conn.body_params do
      %{"password" => pw, "username" => user} ->
        case ServiceDiscovery.AuthStore.verify_user(user, pw) do
          {:ok, user} ->
            send_resp(
              conn,
              200,
              Jason.encode!(%{valid: true, user: user})
            )

          {:error, :invalid_credentials} ->
            send_resp(conn, 401, Jason.encode!(%{message: "Invalid credentials"}))

          _ ->
            send_resp(conn, 401, Jason.encode!(%{message: "Invalid credentials"}))
        end

      _ ->
        send_resp(conn, 401, Jason.encode!(%{message: "Invalid credentials"}))
    end
  end

  post "/candidate" do
    case conn.body_params do
      %{"service_name" => sn, "host" => host, "port" => port} ->
        candidate = %ServiceDiscovery.Candidate{service_name: sn, host: host, port: port}
        ServiceDiscovery.Service.add(candidate.service_name, candidate.host, candidate.port)
        send_resp(conn, 201, Jason.encode!(candidate))

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: service_name, host, port"})
        )
    end
  end

  post "/service/:name/" do
    case conn.body_params do
      %{"host" => host, "port" => port} ->
        candidate = %ServiceDiscovery.Candidate{service_name: name, host: host, port: port}
        ServiceDiscovery.Service.add(candidate.service_name, candidate.host, candidate.port)
        send_resp(conn, 201, Jason.encode!(candidate))

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: host, port"})
        )
    end
  end

  get _ do
    Logger.info("Request path is: #{conn.request_path}")
    send_resp(conn, 404, Jason.encode!(%{error: "No such endpoint"}))
  end
end
