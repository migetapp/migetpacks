# Elixir Example

A simple Elixir HTTP server for testing migetpacks.

## Build

### Standard Build (Linux)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=elixir-example:local \
  miget/migetpacks:local
```

### Standard Build (Mac)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=elixir-example:local \
  -e ARCH=arm64 \
  miget/migetpacks:local
```

> **Note:** Elixir does not support DHI (Docker Hardened Images) as there is no DHI Elixir image available.

## Run

```bash
docker run -p 5000:5000 elixir-example:local
```

Visit http://localhost:5000
