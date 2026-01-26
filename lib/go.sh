#!/bin/bash
# Go build support for migetpacks

# Get Docker images for Go builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
go_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/golang:${version}-dev"
    RUNTIME_IMAGE="dhi.io/golang:${version}"
  else
    BUILD_IMAGE="golang:${version}"
    RUNTIME_IMAGE="debian:bookworm-slim"
  fi
}

# Detect Go module name from go.mod
go_detect_module_name() {
  local build_dir="$1"

  if [ -f "$build_dir/go.mod" ]; then
    grep -E "^module " "$build_dir/go.mod" | head -1 | awk '{print $2}'
  fi
}

# Detect Go binary name from module
go_detect_binary_name() {
  local build_dir="$1"

  local module_name=$(go_detect_module_name "$build_dir")
  if [ -n "$module_name" ]; then
    basename "$module_name"
  else
    echo "app"
  fi
}

# Detect install package spec from go.mod or env
go_detect_packages() {
  local build_dir="$1"

  if [ -n "$GO_INSTALL_PACKAGE_SPEC" ]; then
    echo "$GO_INSTALL_PACKAGE_SPEC"
    return
  fi

  if [ -f "$build_dir/go.mod" ]; then
    local heroku_install=$(grep -E "^//[[:space:]]*\+heroku[[:space:]]+install[[:space:]]+" "$build_dir/go.mod" | \
      sed -E 's/^\/\/[[:space:]]*\+heroku[[:space:]]+install[[:space:]]+//' | head -1)
    if [ -n "$heroku_install" ]; then
      info "Using install directive from go.mod: $heroku_install"
      echo "$heroku_install"
      return
    fi
  fi

  echo "."
}

# Generate builder stage for Go
# Args: dockerfile_path, build_dir, build_command
go_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache IDs for BuildKit PVC cache
  local go_id=$(get_cache_id go)
  local gobuild_id=$(get_cache_id gobuild)

  # Detect binary name and packages
  local binary_name=$(go_detect_binary_name "$build_dir")
  local packages=$(go_detect_packages "$build_dir")

  # Build ldflags for linker symbols
  local ldflags="-s -w"
  if [ -n "$GO_LINKER_SYMBOL" ] && [ -n "$GO_LINKER_VALUE" ]; then
    ldflags="${ldflags} -X ${GO_LINKER_SYMBOL}=${GO_LINKER_VALUE}"
  fi

  # Check for build hooks
  local pre_compile=""
  local post_compile=""
  if [ -f "$build_dir/bin/go-pre-compile" ]; then
    pre_compile="chmod +x bin/go-pre-compile && ./bin/go-pre-compile && "
    info "Found bin/go-pre-compile hook"
  fi
  if [ -f "$build_dir/bin/go-post-compile" ]; then
    post_compile=" && chmod +x bin/go-post-compile && ./bin/go-post-compile"
    info "Found bin/go-post-compile hook"
  fi

  # Check for golang-migrate in go.mod
  local migrate_install=""
  if [ -f "$build_dir/go.mod" ] && grep -q "github.com/golang-migrate/migrate" "$build_dir/go.mod"; then
    migrate_install=" && go install -tags 'postgres mysql' github.com/golang-migrate/migrate/v4/cmd/migrate@latest"
    info "Installing golang-migrate tool"
  fi

  # Go build environment
  cat >> "$dockerfile" <<'EOF'
# Go build environment
ENV CGO_ENABLED=0
ENV GOOS=linux
EOF

  # Copy go.mod and go.sum first for layer caching
  cat >> "$dockerfile" <<'EOF'

# Copy go.mod and go.sum for layer caching (dependencies cached if unchanged)
COPY go.mod go.sum* ./
EOF

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mount for Go modules
    cat >> "$dockerfile" <<EOF

# Download dependencies (cached if go.mod/go.sum unchanged)
RUN --mount=type=cache,id=${go_id},target=/go/pkg/mod,sharing=shared \\
    --mount=type=cache,id=${gobuild_id},target=/root/.cache/go-build,sharing=shared \\
    go mod download

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN --mount=type=cache,id=${go_id},target=/go/pkg/mod,sharing=shared \\
    --mount=type=cache,id=${gobuild_id},target=/root/.cache/go-build,sharing=shared \\
    ${pre_compile}${build_command}${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
    else
      # Build based on package spec
      if [ "$packages" = "." ]; then
        # Single package build
        cat >> "$dockerfile" <<EOF

# Build static binary and cleanup source files
RUN --mount=type=cache,id=${go_id},target=/go/pkg/mod,sharing=shared \\
    --mount=type=cache,id=${gobuild_id},target=/root/.cache/go-build,sharing=shared \\
    ${pre_compile}go build -ldflags="${ldflags}" ${GO_BUILD_FLAGS} -o /build/${binary_name} .${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
      else
        # Multiple packages or pattern (./cmd/...)
        cat >> "$dockerfile" <<EOF

# Build multiple binaries and cleanup source files
RUN --mount=type=cache,id=${go_id},target=/go/pkg/mod,sharing=shared \\
    --mount=type=cache,id=${gobuild_id},target=/root/.cache/go-build,sharing=shared \\
    mkdir -p /build/bin \\
    && ${pre_compile}go build -ldflags="${ldflags}" ${GO_BUILD_FLAGS} -o /build/bin/ ${packages}${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
      fi
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<'EOF'

# Download dependencies
RUN go mod download

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN ${pre_compile}${build_command}${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
    else
      if [ "$packages" = "." ]; then
        cat >> "$dockerfile" <<EOF

# Build static binary and cleanup source files
RUN ${pre_compile}go build -ldflags="${ldflags}" ${GO_BUILD_FLAGS} -o /build/${binary_name} .${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
      else
        cat >> "$dockerfile" <<EOF

# Build multiple binaries and cleanup source files
RUN mkdir -p /build/bin \\
    && ${pre_compile}go build -ldflags="${ldflags}" ${GO_BUILD_FLAGS} -o /build/bin/ ${packages}${migrate_install}${post_compile} \\
    && rm -rf .git .github .gitignore *.go go.mod go.sum vendor/ 2>/dev/null; true
EOF
      fi
    fi
  fi
}

# Generate runtime stage base for Go
# Args: dockerfile_path, runtime_image
go_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"

  cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage
FROM ${runtime_image}

# Install ca-certificates for HTTPS calls
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \\
    && rm -rf /var/lib/apt/lists/*

# Create non-root user with home directory
RUN getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 miget; \\
    getent passwd 1000 >/dev/null 2>&1 || useradd -u 1000 -g 1000 -m miget; \\
    mkdir -p /home/miget && chown 1000:1000 /home/miget

WORKDIR /app

# Copy binary from builder (source files already removed)
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
}

# Generate runtime stage environment for Go
# Args: dockerfile_path, is_dhi_image, dhi_user
go_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  # Check for Go toolchain copy request
  if [ "$GO_INSTALL_TOOLS_IN_IMAGE" = "true" ]; then
    cat >> "$dockerfile" <<'EOF'

# Copy Go toolchain from builder (GO_INSTALL_TOOLS_IN_IMAGE=true)
COPY --from=builder /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:$PATH"
ENV GOROOT=/usr/local/go
EOF
    info "Including Go toolchain in runtime image"
  fi

  # Check for GOPATH setup request
  if [ "$GO_SETUP_GOPATH_IN_IMAGE" = "true" ]; then
    cat >> "$dockerfile" <<'EOF'

# Set up GOPATH (GO_SETUP_GOPATH_IN_IMAGE=true)
ENV GOPATH=/app/go
ENV PATH="$GOPATH/bin:$PATH"
RUN mkdir -p /app/go/bin /app/go/src /app/go/pkg
EOF
    info "Setting up GOPATH in runtime image"
  fi

  # Go production environment
  cat >> "$dockerfile" <<'EOF'

# Go production environment (static binary)
ENV GOTRACEBACK=single
EOF
}
