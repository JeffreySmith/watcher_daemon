defmodule ServiceDiscovery.HTTP do
  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:maybe_authenticate)
  plug(:dispatch)

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp maybe_authenticate(conn, _opts) do
    Logger.debug("Checking if authentication is required for #{conn.request_path}")
    auth_enabled = Application.get_env(:service_discovery, :auth_enabled, false)

    if auth_enabled and conn.method != "GET" do
      authenticate(conn)
    else
      conn
    end
  end

  defp authenticate(conn) do
    Logger.debug("Authenticating request to #{conn.request_path}")

    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [user, pw] <- String.split(decoded, ":", parts: 2),
         {:ok, _user} <- ServiceDiscovery.AuthStore.verify_user(user, pw) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end

  defp candidate_to_tuple(%{service_name: sn, host: h, port: p})
       when is_binary(sn) and is_binary(h) and is_integer(p), do: {sn, h, p}

  defp candidate_to_tuple(candidate) when is_map(candidate) do
    sn = Map.get(candidate, :service_name) || Map.get(candidate, "service_name")
    h = Map.get(candidate, :host)
    p = Map.get(candidate, :port)
    if is_nil(sn) or is_nil(h) or is_nil(p), do: :invalid, else: {sn, h, p}
  end

  get "/" do
    send_resp(conn, 200, "Service Discovery API")
  end

  get "/candidate" do
    case ServiceDiscovery.CandidateStore.get_one_available() do
      nil ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))

      cand ->
        case candidate_to_tuple(cand) do
          :invalid ->
            Logger.error("[HTTP] /candidate: invalid candidate shape: #{inspect(cand)}")
            send_json(conn, 500, %{error: "Internal server error"})

          {service_name, host, port} ->
            send_json(conn, 200, %{service: service_name, host: host, port: port})
        end
    end
  end

  get "/candidates" do
    candidates =
      ServiceDiscovery.CandidateStore.cached_all()

    case candidates do
      [] ->
        send_resp(conn, 503, Jason.encode!(%{error: "No candidates available"}))

      _ ->
        send_json(conn, 200, candidates)
    end
  end

  get "/service/:name" do
    out = ServiceDiscovery.Service.first_available()

    case out do
      {:ok, cand} ->
        case candidate_to_tuple(cand) do
          {^name, host, port} ->
            send_json(conn, 200, %{service_name: name, host: host, port: port})

          {_other_service, _host, _port} ->
            send_json(conn, 503, %{error: "No candidates available for service '#{name}'"})

          :invalid ->
            Logger.error("[HTTP] /service/#{name}: invalid candidate : #{inspect(cand)}")
            send_json(conn, 500, %{error: "Internal server error"})
        end

      {:error, :none_available} ->
        send_resp(
          conn,
          503,
          Jason.encode!(%{error: "No candidates available for service '#{name}'"})
        )

      _ ->
        send_json(conn, 500, %{error: "Internal error"})
    end
  end

  get "/service/:name/candidates" do
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

  patch "/candidate" do
    Logger.warning("Received PATCH /candidate with body: #{inspect(conn.body_params)}")

    case conn.body_params do
      %{"service_name" => sn, "host" => host, "port" => port} = params ->
        new_host = Map.get(params, "new_host", host)
        new_port = Map.get(params, "new_port", port)

        case ServiceDiscovery.CandidateStore.member?(sn, host, port) do
          false ->
            send_json(conn, 404, %{error: "Candidate not found"})

          true ->
            ServiceDiscovery.Service.remove(sn, host, port)
            ServiceDiscovery.Service.add(sn, new_host, new_port)
            send_json(conn, 200, %{service_name: sn, host: new_host, port: new_port})
        end

      _ ->
        send_json(conn, 400, %{error: "Missing required fields: service_name, host, port"})
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

  delete "/candidate" do
    case conn.body_params do
      %{"service_name" => sn, "host" => host, "port" => port} ->
        candidate = %ServiceDiscovery.Candidate{service_name: sn, host: host, port: port}
        ServiceDiscovery.Service.remove(candidate.service_name, candidate.host, candidate.port)
        send_resp(conn, 200, Jason.encode!(%{message: "Candidate removed"}))

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
        if ServiceDiscovery.CandidateStore.member?(name, host, port) do
          send_resp(
            conn,
            409,
            Jason.encode!(%{error: "Candidate (#{name}, #{host}, #{port}) already exists"})
          )
        else
          candidate = %ServiceDiscovery.Candidate{service_name: name, host: host, port: port}
          ServiceDiscovery.Service.add(candidate.service_name, candidate.host, candidate.port)
          send_resp(conn, 201, Jason.encode!(candidate))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: host, port"})
        )
    end
  end

  patch "/service/:name/" do
    case conn.body_params do
      %{"host" => host, "port" => port} = params ->
        new_host = Map.get(params, "new_host", host)
        new_port = Map.get(params, "new_port", port)

        Logger.info("#{name} #{host} #{port}")
        Logger.info("#{name} #{new_host}, #{new_port}")

        if not ServiceDiscovery.CandidateStore.member?(name, host, port) do
          send_resp(conn, 404, Jason.encode!(%{error: "Candidate not found"}))
        else
          ServiceDiscovery.Service.remove(name, host, port)
          ServiceDiscovery.Service.add(name, new_host, new_port)

          send_resp(
            conn,
            200,
            Jason.encode!(%{service_name: name, host: new_host, port: new_port})
          )
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: host, port"})
        )
    end
  end

  delete "/service/:name/" do
    case conn.body_params do
      %{"host" => host, "port" => port} ->
        if not ServiceDiscovery.CandidateStore.member?(name, host, port) do
          send_resp(conn, 404, Jason.encode!(%{error: "Candidate not found"}))
        else
          candidate = %ServiceDiscovery.Candidate{service_name: name, host: host, port: port}
          ServiceDiscovery.Service.remove(candidate.service_name, candidate.host, candidate.port)
          send_resp(conn, 200, Jason.encode!(%{message: "Candidate removed"}))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: host, port"})
        )
    end
  end

  post "/user" do
    case conn.body_params do
      %{"username" => user, "password" => pw} ->
        if ServiceDiscovery.AuthStore.member?(user) do
          send_resp(conn, 409, Jason.encode!(%{error: "Invalid user"}))
        else
          ServiceDiscovery.AuthStore.create_user(user, pw)
          send_resp(conn, 201, Jason.encode!(%{message: "User created"}))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: username, password"})
        )
    end
  end

  patch "/user" do
    case conn.body_params do
      %{"username" => user, "password" => pw} ->
        if not ServiceDiscovery.AuthStore.member?(user) do
          send_resp(conn, 404, Jason.encode!(%{error: "Invalid user"}))
        else
          ServiceDiscovery.AuthStore.change_password(user, pw)
          send_resp(conn, 200, Jason.encode!(%{message: "User updated"}))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required fields: username, password"})
        )
    end
  end

  delete "/user" do
    case conn.body_params do
      %{"username" => user} ->
        if not ServiceDiscovery.AuthStore.member?(user) do
          send_resp(conn, 404, Jason.encode!(%{error: "Invalid user"}))
        else
          ServiceDiscovery.AuthStore.delete_user(user)
          send_resp(conn, 200, Jason.encode!(%{message: "User deleted"}))
        end

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{error: "Missing required field: username"})
        )
    end
  end

  get _ do
    Logger.info("Request path is: #{conn.request_path}")
    send_resp(conn, 404, Jason.encode!(%{error: "No such endpoint"}))
  end
end
