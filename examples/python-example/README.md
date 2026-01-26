# Python Example

A simple Python HTTP server for testing migetpacks.

## Build

### Standard Build (Linux)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=python-example:local \
  miget/migetpacks:local
```

### DHI Build (Mac with Docker Desktop)

```bash
DHI_USERNAME=$(echo "dhi.io" | docker-credential-desktop get | jq -r '.Username')
DHI_PASSWORD=$(echo "dhi.io" | docker-credential-desktop get | jq -r '.Secret')

docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=python-example:local \
  -e ARCH=arm64 \
  -e USE_DHI=true \
  -e DHI_USERNAME="$DHI_USERNAME" \
  -e DHI_PASSWORD="$DHI_PASSWORD" \
  miget/migetpacks:local
```

## Run

```bash
docker run -p 5000:5000 python-example:local
```

Visit http://localhost:5000
