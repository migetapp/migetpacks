package com.miget.hello;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;

public class Application {
    private static final String HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Java Hello World - Miget</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
            min-height: 100vh;
            background: linear-gradient(135deg, #1a1a2e 0%%, #16213e 50%%, #0f3460 100%%);
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
        <h1>Hello, %s!</h1>
        <p class="greeting">Welcome to Java application built by Migetpacks</p>
        <div class="info-card">
            <div class="info-row">
                <span class="info-label">Runtime</span>
                <span class="info-value">Java</span>
            </div>
            <div class="info-row">
                <span class="info-label">Version</span>
                <span class="info-value">%s</span>
            </div>
            <div class="info-row">
                <span class="info-label">Vendor</span>
                <span class="info-value">%s</span>
            </div>
        </div>
        <span class="badge">Built with Migetpacks</span>
    </div>
</body>
</html>""";

    private static String escapeHtml(String s) {
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#39;");
    }

    public static void main(String[] args) throws IOException {
        String portEnv = System.getenv("PORT");
        int port = portEnv != null ? Integer.parseInt(portEnv) : 5000;

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/logo.png", new LogoHandler());
        server.createContext("/", new HelloHandler());
        server.setExecutor(null);

        System.out.println("Server running on http://localhost:" + port);
        server.start();
    }

    static class LogoHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try (var is = Application.class.getResourceAsStream("/logo.png")) {
                if (is == null) {
                    exchange.sendResponseHeaders(404, 0);
                    return;
                }
                byte[] logo = is.readAllBytes();
                exchange.getResponseHeaders().set("Content-Type", "image/png");
                exchange.sendResponseHeaders(200, logo.length);
                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(logo);
                }
            }
        }
    }

    static class HelloHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String query = exchange.getRequestURI().getQuery();
            String name = "World";
            if (query != null && query.startsWith("name=")) {
                name = query.substring(5);
            }

            String response = String.format(HTML_TEMPLATE,
                escapeHtml(name),
                System.getProperty("java.version"),
                System.getProperty("java.vendor"));

            exchange.getResponseHeaders().set("Content-Type", "text/html");
            exchange.sendResponseHeaders(200, response.getBytes().length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(response.getBytes());
            }
        }
    }
}
