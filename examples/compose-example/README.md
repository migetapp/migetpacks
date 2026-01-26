# Compose Example

An example of building multiple services from a compose file.

## Build

### Standard Build (Linux)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=compose-example:local \
  miget/migetpacks:local
```

### Standard Build (Mac)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=compose-example:local \
  -e ARCH=arm64 \
  miget/migetpacks:local
```

This builds all services defined in `compose.yaml`, creating images like:
- `compose-example-api:local`
- `compose-example-web:local`

> **Note:** Compose builds use each service's Dockerfile or auto-detect language. DHI support depends on the languages detected.

## Run

```bash
docker compose up
```

Visit http://localhost:5000
