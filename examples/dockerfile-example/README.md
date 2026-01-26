# Dockerfile Example

An example of using a custom Dockerfile with migetpacks.

## Build

### Standard Build (Linux)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=dockerfile-example:local \
  -e LANGUAGE=dockerfile \
  miget/migetpacks:local
```

### Standard Build (Mac)

```bash
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=dockerfile-example:local \
  -e LANGUAGE=dockerfile \
  -e ARCH=arm64 \
  miget/migetpacks:local
```

> **Note:** Custom Dockerfiles are built as-is. DHI support depends on the base images used in your Dockerfile.

## Run

```bash
docker run -p 5000:5000 dockerfile-example:local
```

Visit http://localhost:5000
