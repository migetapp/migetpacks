defmodule ElixirExample.Application do
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT") || "5000")

    children = [
      {Plug.Cowboy, scheme: :http, plug: ElixirExample.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: ElixirExample.Supervisor]
    IO.puts("Server running on http://localhost:#{port}")
    Supervisor.start_link(children, opts)
  end
end
