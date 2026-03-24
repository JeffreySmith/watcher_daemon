defmodule ServiceDiscovery.AuditLog do
  @moduledoc """
    A plug that logs all requests with user, IP, method, path, and body.
    Passwords are masked in the output.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    masked_fields =
      Application.get_env(
        :service_discovery,
        :masked_fields,
        "password secret token old_password"
      )
      |> String.split()

    user = extract_user(conn)
    ip = extract_ip(conn)
    masked_body = conn.body_params |> mask_sensitive()
    masked_timestamp = if "timestamp" in masked_fields, do: "[MASKED]", else: DateTime.utc_now()

    masked_user = if "user" in masked_fields, do: "[MASKED]", else: user
    masked_ip = if "ip" in masked_fields, do: "[MASKED]", else: ip
    masked_path = if "path" in masked_fields, do: "[MASKED]", else: conn.request_path

    entry =
      Jason.encode!(%{
        timestamp: masked_timestamp,
        user: masked_user,
        ip: masked_ip,
        method: conn.method,
        path: masked_path,
        body: masked_body
      })

    Logger.info(
      "[AuditLog] #{conn.method} #{conn.request_path} " <>
        "user=#{user} ip=#{ip} body=#{inspect(masked_body)}"
    )

    append_to_file(entry)

    conn
  end

  defp extract_user(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded |> String.split(":", parts: 2) |> List.first()
          _ -> "unknown"
        end

      # Not currently implemented
      ["Bearer " <> _] ->
        "token_user"

      _ ->
        "anonymous"
    end
  end

  defp extract_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip |> String.split(",") |> List.first() |> String.trim()
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp mask_sensitive(params) when is_map(params) do
    masked_fields =
      Application.get_env(
        :service_discovery,
        :masked_fields,
        "password secret token old_password"
      )
      |> String.split()

    Map.new(params, fn {k, v} ->
      if k in masked_fields do
        {k, "[MASKED]"}
      else
        {k, mask_sensitive(v)}
      end
    end)
  end

  defp mask_sensitive(value), do: value

  def append_to_file(entry) do
    log_path = Application.get_env(:service_discovery, :audit_log_path, "") |> String.trim()

    if log_path != "" do
      case File.write(log_path, entry <> "\n", [:append]) do
        :ok ->
          Logger.debug("[AuditLog] logged reload event to #{log_path}")

        {:error, reason} ->
          Logger.error("[AuditLog] failed to log reload event: #{inspect(reason)}")
      end
    end
  end
end
