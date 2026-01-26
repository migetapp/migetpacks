# PHP Hello World

A simple PHP HTTP server for testing migetpacks.

## Build

### Standard Build (Linux)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=php-hello-world:local \
  miget/migetpacks:local
```

### Standard Build (Mac)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=php-hello-world:local \
  -e ARCH=arm64 \
  miget/migetpacks:local
```

> **Note:** PHP uses FrankenPHP which does not support DHI (Docker Hardened Images).

## Run

```bash
docker run -p 5000:5000 php-hello-world:local
```

Visit http://localhost:5000
