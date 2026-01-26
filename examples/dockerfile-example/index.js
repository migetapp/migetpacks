const http = require('http');
const fs = require('fs');
const path = require('path');

const port = process.env.PORT || 5000;

const escapeHtml = (str) => str.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const html = (name) => `<!DOCTYPE html>
<html>
<head>
    <title>Dockerfile Example - Miget</title>
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
        .dockerfile-badge {
            background: linear-gradient(90deg, #f093fb, #f5576c);
        }
    </style>
</head>
<body>
    <div class="container">
        <img src="/logo.png" alt="Miget" class="logo">
        <h1>Hello, ${escapeHtml(name)}!</h1>
        <p class="greeting">Built using a custom Dockerfile</p>
        <div class="info-card">
            <div class="info-row">
                <span class="info-label">Build Type</span>
                <span class="info-value">Custom Dockerfile</span>
            </div>
            <div class="info-row">
                <span class="info-label">Runtime</span>
                <span class="info-value">Node.js</span>
            </div>
            <div class="info-row">
                <span class="info-label">Version</span>
                <span class="info-value">${process.version}</span>
            </div>
            <div class="info-row">
                <span class="info-label">Platform</span>
                <span class="info-value">${process.platform}/${process.arch}</span>
            </div>
        </div>
        <span class="badge dockerfile-badge">Custom Dockerfile</span>
    </div>
</body>
</html>`;

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${port}`);

    if (url.pathname === '/logo.png') {
        const logoPath = path.join(__dirname, 'logo.png');
        fs.readFile(logoPath, (err, data) => {
            if (err) {
                res.writeHead(404);
                res.end('Not found');
            } else {
                res.writeHead(200, { 'Content-Type': 'image/png' });
                res.end(data);
            }
        });
        return;
    }

    const name = url.searchParams.get('name') || 'World';
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html(name));
});

server.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://localhost:${port}`);
});
