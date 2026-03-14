import Config

config :service_discovery,
  peers:
    System.get_env("PEERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1),
  candidates:
    System.get_env("CANDIDATES", "")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn entry ->
      case String.split(entry, ":") do
        ["", _] ->
          [{:error, "Empty host"}]

        [host, ""] ->
          [{:error, "Empty port for '#{host}'"}]

        [host] ->
          [{:error, "No port provided for '#{host}'"}]

        [host, port] ->
          case Integer.parse(port) do
            {p, ""} ->
              [{host, p}]

            {_, invalid_chars} ->
              [{:error, "Invalid characters for '#{host}' port: #{invalid_chars}"}]

            :error ->
              [{:error, "Invalid port #{port} for '#{host}'"}]
          end
      end
    end),
  discovery_timeout_ms: 5_000,
  http_port: String.to_integer(System.get_env("HTTP_PORT", "4000"))
