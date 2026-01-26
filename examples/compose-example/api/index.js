const http = require('http');

const port = process.env.PORT || 5000;

const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        service: 'api',
        message: 'Hello from API service!',
        version: process.version,
        platform: `${process.platform}/${process.arch}`,
        timestamp: new Date().toISOString()
    }));
});

server.listen(port, '0.0.0.0', () => {
    console.log(`API server running on http://localhost:${port}`);
});
