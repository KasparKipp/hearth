defmodule Hearth.TestHTTP do
  @moduledoc false

  # A minimal HTTP/1.1 server on 127.0.0.1 for exercising
  # `Hearth.Spec.Fetcher` without the network. `start/1` takes
  # `%{path => {status, headers, body}}` and returns the port; unknown
  # paths get a 404. Each connection serves one request, then closes.

  @spec start(%{String.t() => {pos_integer(), [{String.t(), String.t()}], binary()}}) ::
          :inet.port_number()
  def start(routes) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept(listen, routes) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    port
  end

  defp accept(listen, routes) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, routes)
        accept(listen, routes)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, routes) do
    with {:ok, request} <- read_head(socket, ""),
         [line | _] <- String.split(request, "\r\n"),
         [_method, path | _] <- String.split(line, " ") do
      {status, headers, body} = Map.get(routes, path, {404, [], "not found"})

      head =
        Enum.map_join(
          [
            {"content-length", Integer.to_string(byte_size(body))},
            {"connection", "close"} | headers
          ],
          "",
          fn {name, value} -> "#{name}: #{value}\r\n" end
        )

      :gen_tcp.send(socket, "HTTP/1.1 #{status} Status\r\n#{head}\r\n#{body}")
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, acc <> data)
        error -> error
      end
    end
  end
end
