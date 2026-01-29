# migetpacks

**Auto-detecting buildpacks for container images** - automatically detects your language, version, and builds optimized container images using official upstream Docker images.

Built by [miget.com](https://miget.com) - Unlimited apps, one price.

[![License](https://img.shields.io/badge/license-O'Saasy-blue.svg)](https://github.com/migetapp/migetpacks/blob/main/LICENSE)
[![Docker Image](https://img.shields.io/badge/docker-miget%2Fmigetpacks-blue)](https://hub.docker.com/r/miget/migetpacks)

## Features

- **Zero Config** - Automatically detects language, version, and builds your app
- **14 Languages** - Node.js, Deno, Bun, Python, Ruby, Go, Rust, Java, Kotlin, Scala, Clojure, .NET, PHP, Elixir
- **Secure by Default** - Optional [Docker Hardened Images](https://dhi.io) (distroless, CVE-free)
- **Multi-Buildpack** - Combine languages (e.g., Ruby + Node.js for asset compilation)
- **Procfile Support** - Standard process definitions
- **Non-root Runtime** - All containers run as non-root user
- **Fast Builds** - BuildKit layer caching and registry-based caching

## Requirements

- **Docker Desktop** (macOS/Windows) or **Docker Engine** (Linux)
- **BuildKit enabled** (default in Docker Desktop 4.0+)

migetpacks runs Docker-in-Docker using BuildKit for optimized multi-stage builds. It requires access to the Docker socket (`/var/run/docker.sock`).

```bash
# Verify Docker is running
docker info

# Verify BuildKit is available
docker buildx version
```

## Quick Start

### Docker

```bash
# Build your app
docker run --rm \
  -v /path/to/your/app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  miget/migetpacks:latest

# Run your app
docker run -p 5000:5000 my-app:latest
```

### GitHub Actions (GitHub-hosted runners)

For ephemeral `ubuntu-latest` runners, use registry-based caching via `CACHE_IMAGE`:

```yaml
name: Build and Push

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # Required for CACHE_IMAGE support
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push with migetpacks
        run: |
          docker run --rm \
            -v ${{ github.workspace }}:/workspace/source:ro \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /home/runner/.docker/config.json:/root/.docker/config.json:ro \
            -e OUTPUT_IMAGE=ghcr.io/${{ github.repository }}:${{ github.sha }} \
            -e CACHE_IMAGE=ghcr.io/${{ github.repository }}:cache \
            miget/migetpacks:latest
```

### GitHub Actions (Self-hosted runners)

For persistent self-hosted runners, use local file cache via `BUILD_CACHE_DIR`:

```yaml
name: Build and Push

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v4

      - name: Log in to registry
        uses: docker/login-action@v3
        with:
          registry: registry.example.com
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}

      - name: Build and push with migetpacks
        run: |
          docker run --rm \
            -v ${{ github.workspace }}:/workspace/source:ro \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v $HOME/.docker/config.json:/root/.docker/config.json:ro \
            -v /var/cache/migetpacks:/cache \
            -e OUTPUT_IMAGE=registry.example.com/my-app:${{ github.sha }} \
            -e BUILD_CACHE_DIR=/cache \
            miget/migetpacks:latest
```

**Cache options:**
- `CACHE_IMAGE` - Registry-based BuildKit layer cache. Requires `docker/setup-buildx-action`. Works on ephemeral runners.
- `BUILD_CACHE_DIR` - Local directory for package manager caches (npm, pip, bundler, etc.). Best for persistent self-hosted runners.

## Supported Languages

| Language | Detection | Version Source |
|----------|-----------|----------------|
| Node.js | `package.json` | `.nvmrc`, `.node-version`, `package.json` |
| Deno | `deno.json`, `deno.jsonc` | `deno.json` |
| Bun | `bun.lockb`, `bunfig.toml` | `package.json` |
| Python | `requirements.txt`, `Pipfile`, `pyproject.toml` | `.python-version`, `runtime.txt` |
| Ruby | `Gemfile` | `.ruby-version`, `Gemfile` |
| Go | `go.mod` | `go.mod` |
| Rust | `Cargo.toml` | `Cargo.toml` |
| PHP | `composer.json`, `index.php` | `composer.json` |
| Java | `pom.xml`, `build.gradle` | `pom.xml`, `.java-version`, `system.properties` |
| Kotlin | `build.gradle.kts` | `system.properties` |
| Scala | `build.sbt` | `system.properties` |
| Clojure | `project.clj`, `deps.edn` | `system.properties` |
| .NET | `*.csproj`, `*.fsproj` | `global.json`, `*.csproj` |
| Elixir | `mix.exs` | `mix.exs`, `.elixir-version` |
| Dockerfile | `Dockerfile` | - |
| Compose | `compose.yaml`, `docker-compose.yml` | - |

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OUTPUT_IMAGE` | **Yes** | - | Target image name (e.g., `ghcr.io/user/app:tag`) |
| `SOURCE_DIR` | No | `/workspace/source` | Source code directory |
| `LANGUAGE` | No | auto-detected | Force language (see values below) |
| `RUN_COMMAND` | No | from Procfile | Override the run command |
| `PORT` | No | `5000` | Application port |
| `ARCH` | No | `x86_64` | Target architecture (`x86_64`, `arm64`) |
| `PROJECT_PATH` | No | - | Subdirectory for monorepo builds |
| `BUILDPACKS` | No | auto-detected | Explicit buildpack order (e.g., `ruby,nodejs`) |
| `DOCKERFILE_PATH` | No | - | Custom Dockerfile path (forces `dockerfile` language) |
| `COMPOSE_FILE` | No | - | Custom compose file path (forces `compose` language) |
| `TAG_LATEST` | No | `false` | Also tag image with `:latest` in addition to primary tag |
| `RESULT_FILE` | No | - | Path to write build results JSON |
| `STORAGE_DRIVER` | No | `overlay2` | Docker storage driver (e.g., `fuse-overlayfs` for nested DinD) |

### Caching Options

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CACHE_IMAGE` | No | - | Registry image for BuildKit cache |
| `CACHE_MODE` | No | `min` | BuildKit cache export mode: `min` (final layer) or `max` (all layers) |
| `CACHE_FROM` | No | - | Additional read-only cache sources (comma-separated registry refs) |
| `CACHE_REGISTRY_INSECURE` | No | `false` | Set to `true` for HTTP registries |
| `NO_CACHE` | No | `false` | Force fresh build, skips cache-from |
| `BUILD_CACHE_DIR` | No | - | Directory for package manager cache |
| `REGISTRY_MIRROR` | No | - | Docker registry mirror URL |

### Docker Hardened Images

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `USE_DHI` | No | `false` | Use Docker Hardened Images from [dhi.io](https://dhi.io) |
| `DHI_USERNAME` | No | - | DHI registry username (alternative to mounting docker config) |
| `DHI_PASSWORD` | No | - | DHI registry password/token |
| `DHI_MIRROR` | No | - | DHI registry mirror URL |

### Custom Build Environment Variables

Any environment variable passed to migetpacks that is **not** a known configuration variable will be automatically injected into the generated Dockerfile as `ENV` statements. This allows you to pass custom build-time settings without modifying migetpacks.

```bash
# Pass NODE_OPTIONS to increase heap size for large builds
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  -e NODE_OPTIONS="--max-old-space-size=4096" \
  miget/migetpacks:latest

# Pass multiple custom variables
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  -e NODE_OPTIONS="--max-old-space-size=4096" \
  -e VITE_API_URL="https://api.example.com" \
  -e MY_BUILD_FLAG="true" \
  miget/migetpacks:latest
```

**Common use cases:**
- `NODE_OPTIONS="--max-old-space-size=4096"` - Increase Node.js heap for large builds
- `VITE_*` / `NEXT_PUBLIC_*` - Frontend build-time variables
- `RAILS_MASTER_KEY` - Rails credentials key for asset precompilation
- Custom feature flags for conditional compilation

**Note:** Sensitive variables like `AWS_*` credentials and Docker configuration are automatically filtered out and never injected into the Dockerfile.

### LANGUAGE Values

Force a specific language by setting `LANGUAGE`:

| Value | Description |
|-------|-------------|
| `nodejs` | Node.js (npm, yarn, pnpm) |
| `deno` | Deno runtime |
| `bun` | Bun runtime |
| `python` | Python (pip, uv) |
| `ruby` | Ruby (bundler) |
| `go` | Go |
| `rust` | Rust (cargo) |
| `php` | PHP (FrankenPHP + Composer) |
| `java` | Java (Maven or Gradle) |
| `kotlin` | Kotlin (Gradle) |
| `scala` | Scala (sbt) |
| `clojure` | Clojure (Leiningen) |
| `.net` or `dotnet` | .NET / C# |
| `elixir` | Elixir (Mix) |
| `dockerfile` | Use project's Dockerfile directly |
| `compose` | Build all services from compose.yaml |

## Procfile Support

Define processes in a `Procfile`:

```
web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq
release: bundle exec rails db:migrate
```

Priority order:
1. `RUN_COMMAND` environment variable
2. `web:` process from Procfile
3. First process in Procfile
4. Language-specific default

## Multi-Buildpack

Build apps with multiple languages:

```bash
# Ruby app with Node.js for asset compilation
docker run --rm \
  -v ./my-rails-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-rails-app:latest \
  -e BUILDPACKS=ruby,nodejs \
  miget/migetpacks:latest
```

## Docker Hardened Images

Use minimal, CVE-free [Docker Hardened Images](https://dhi.io):

```bash
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  -e USE_DHI=true \
  miget/migetpacks:latest
```

DHI images are distroless (no shell, no apt-get) with minimal attack surface.

### Docker Desktop (Mac/Windows)

Docker Desktop stores credentials in the system keychain, not in `~/.docker/config.json`. Extract credentials and pass them as environment variables:

```bash
# Extract credentials from Docker Desktop keychain
DHI_USERNAME=$(echo "dhi.io" | docker-credential-desktop get | jq -r '.Username')
DHI_PASSWORD=$(echo "dhi.io" | docker-credential-desktop get | jq -r '.Secret')

# Build with DHI
docker run --rm \
  -v "$(pwd):/workspace/source:ro" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:local \
  -e ARCH=arm64 \
  -e USE_DHI=true \
  -e DHI_USERNAME="$DHI_USERNAME" \
  -e DHI_PASSWORD="$DHI_PASSWORD" \
  miget/migetpacks:latest
```

## Dockerfile & Compose Support

### Custom Dockerfile

migetpacks prioritizes its optimized builds for known languages. A `Dockerfile` is only used as a **fallback** when no supported language is detected. To force your Dockerfile, use `LANGUAGE=dockerfile`:

```bash
# Force Dockerfile mode (recommended when you have both language files and Dockerfile)
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  -e LANGUAGE=dockerfile \
  miget/migetpacks:latest

# Fallback behavior (uses Dockerfile only if no language detected)
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  miget/migetpacks:latest

# Use custom Dockerfile path
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=my-app:latest \
  -e DOCKERFILE_PATH=docker/Dockerfile.prod \
  miget/migetpacks:latest
```

### Docker Compose

Multi-service builds from `compose.yaml`:

```yaml
# compose.yaml
services:
  api:
    build: ./api
  web:
    build: ./web
```

```bash
# Auto-detect compose file
docker run --rm \
  -v ./my-project:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=ghcr.io/user/myproject:latest \
  miget/migetpacks:latest
# Builds: ghcr.io/user/myproject-api:latest, ghcr.io/user/myproject-web:latest

# Force compose mode
docker run --rm \
  -v ./my-project:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=ghcr.io/user/myproject:latest \
  -e LANGUAGE=compose \
  miget/migetpacks:latest
```

## Monorepo Support

Build a specific subdirectory:

```bash
docker run --rm \
  -v ./monorepo:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e PROJECT_PATH=services/api \
  -e OUTPUT_IMAGE=my-api:latest \
  miget/migetpacks:latest
```

## Build Caching

### Package Manager Cache

Mount a cache directory for npm, pip, bundler, cargo, etc.:

```bash
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /path/to/cache:/cache \
  -e OUTPUT_IMAGE=my-app:latest \
  -e BUILD_CACHE_DIR=/cache \
  miget/migetpacks:latest
```

### Registry Cache

Use BuildKit's registry-based caching for Docker layer caching:

```bash
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OUTPUT_IMAGE=ghcr.io/user/my-app:latest \
  -e CACHE_IMAGE=ghcr.io/user/my-app-cache \
  miget/migetpacks:latest
```

## Private Registry Authentication

When pushing to private registries, migetpacks needs access to your Docker credentials. Since migetpacks runs inside a container, you must mount the Docker config directory.

### Docker

```bash
# Log in to your registry first
docker login registry.example.com

# Mount the docker config so migetpacks can push
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.docker/config.json:/root/.docker/config.json:ro \
  -e OUTPUT_IMAGE=registry.example.com/my-app:latest \
  miget/migetpacks:latest
```

### GitHub Actions

```yaml
- name: Log in to registry
  uses: docker/login-action@v3
  with:
    registry: registry.example.com
    username: ${{ secrets.REGISTRY_USERNAME }}
    password: ${{ secrets.REGISTRY_PASSWORD }}

- name: Build and push with migetpacks
  run: |
    docker run --rm \
      -v ${{ github.workspace }}:/workspace/source:ro \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /home/runner/.docker/config.json:/root/.docker/config.json:ro \
      -e OUTPUT_IMAGE=registry.example.com/my-app:${{ github.sha }} \
      -e CACHE_IMAGE=registry.example.com/my-app:cache \
      miget/migetpacks:latest
```

**Key points:**
- Mount `config.json` file only (buildx needs to create state in `.docker/buildx/`)
- Use `:ro` (read-only) for the config file
- On GitHub-hosted runners, the path is `/home/runner/.docker/config.json`
- On self-hosted runners, use `$HOME/.docker/config.json`

## Build Results

Get structured JSON output for CI/CD pipelines:

```bash
docker run --rm \
  -v ./my-app:/workspace/source \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/results:/output \
  -e OUTPUT_IMAGE=my-app:latest \
  -e RESULT_FILE=/output/result.json \
  miget/migetpacks:latest

cat /tmp/results/result.json
```

```json
{
  "status": "success",
  "images": [{"name": "my-app:latest", "ports": ["5000/tcp"]}],
  "processes": {"web": "node server.js"},
  "language": "nodejs",
  "build_time": 45
}
```

## Examples

Working examples for all languages in [`examples/`](https://github.com/migetapp/migetpacks/tree/main/examples):

- `nodejs-example`, `deno-example`, `bun-example`
- `python-example`, `ruby-example`, `php-hello-world`
- `go-hello-world`, `rust-example`
- `java-hello-world`, `kotlin-example`, `scala-example`
- `dotnet-hello-world`, `elixir-example`
- `dockerfile-example`, `compose-example`

## Development

```bash
# Run detection tests
make test-detect

# Build the container locally
make build

# Test a language build
make test-nodejs
make test-python
make test-go
```

## About

migetpacks is built by [miget.com](https://miget.com) - unlimited apps, one price. We use migetpacks to build customer apps with zero configuration.

## License

O'Saasy License (Modified for Cloud/PaaS) - see [LICENSE](https://github.com/migetapp/migetpacks/blob/main/LICENSE) for details.
