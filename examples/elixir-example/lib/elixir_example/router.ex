defmodule ElixirExample.Router do
  use Plug.Router

  plug :fetch_query_params
  plug :match
  plug :dispatch

  get "/logo.png" do
    logo_path = Path.join(:code.priv_dir(:elixir_example), "logo.png")
    conn
    |> put_resp_content_type("image/png")
    |> send_file(200, logo_path)
  end

  get "/" do
    name = conn.query_params["name"] || "World"
    name = HtmlEntities.encode(name)

    html = """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Elixir Hello World - Miget</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
                min-height: 100vh;
                background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
                color: #ffffff;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                padding: 2rem;
            }
            .container { text-align: center; max-width: 600px; }
            .logo { width: 200px; margin-bottom: 2rem; }
            h1 {
                font-size: 2.5rem;
                margin-bottom: 0.5rem;
                background: linear-gradient(90deg, #00d4ff, #7b2cbf);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
                background-clip: text;
            }
            .greeting { font-size: 1.5rem; color: #e0e0e0; margin-bottom: 2rem; }
            .info-card {
                background: rgba(255, 255, 255, 0.05);
                border: 1px solid rgba(255, 255, 255, 0.1);
                border-radius: 12px;
                padding: 1.5rem;
                margin-top: 1rem;
            }
            .info-row {
                display: flex;
                justify-content: space-between;
                padding: 0.5rem 0;
                border-bottom: 1px solid rgba(255, 255, 255, 0.05);
            }
            .info-row:last-child { border-bottom: none; }
            .info-label { color: #888; }
            .info-value { color: #00d4ff; font-family: monospace; }
            .badge {
                display: inline-block;
                background: linear-gradient(90deg, #00d4ff, #7b2cbf);
                color: white;
                padding: 0.25rem 0.75rem;
                border-radius: 20px;
                font-size: 0.875rem;
                margin-top: 1rem;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <img src="/logo.png" alt="Miget" class="logo">
            <h1>Hello, #{name}!</h1>
            <p class="greeting">Welcome to Elixir application built by Migetpacks</p>
            <div class="info-card">
                <div class="info-row">
                    <span class="info-label">Runtime</span>
                    <span class="info-value">Elixir/OTP</span>
                </div>
                <div class="info-row">
                    <span class="info-label">Elixir</span>
                    <span class="info-value">#{System.version()}</span>
                </div>
                <div class="info-row">
                    <span class="info-label">OTP</span>
                    <span class="info-value">#{:erlang.system_info(:otp_release)}</span>
                </div>
            </div>
            <span class="badge">Built with Migetpacks</span>
        </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end

defmodule HtmlEntities do
  def encode(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
