#!/bin/bash
# Rust build support for migetpacks

# Get Docker images for Rust builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
rust_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/rust:${version}-dev"
    RUNTIME_IMAGE="dhi.io/rust:${version}"
  else
    BUILD_IMAGE="rust:${version}"
    RUNTIME_IMAGE="debian:bookworm-slim"
  fi
}

# Detect binary name from Cargo.toml
rust_detect_binary_name() {
  local build_dir="$1"

  if [ -f "$build_dir/Cargo.toml" ]; then
    # Check for [[bin]] section first
    local bin_name=$(grep -A5 '^\[\[bin\]\]' "$build_dir/Cargo.toml" | grep -E '^name\s*=' | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ -n "$bin_name" ]; then
      echo "$bin_name"
      return
    fi
    # Fall back to package name
    grep -E '^name\s*=' "$build_dir/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/'
  else
    echo "app"
  fi
}

# Check if project has workspace
rust_is_workspace() {
  local build_dir="$1"

  if [ -f "$build_dir/Cargo.toml" ]; then
    grep -q '^\[workspace\]' "$build_dir/Cargo.toml"
  else
    return 1
  fi
}

# Generate builder stage for Rust
# Args: dockerfile_path, build_dir, build_command
rust_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache IDs for BuildKit PVC cache
  local cargo_id=$(get_cache_id cargo)
  local rustbuild_id=$(get_cache_id rustbuild)

  # Detect binary name
  local binary_name=$(rust_detect_binary_name "$build_dir")
  info "Detected Rust binary: $binary_name"

  # Check if workspace project
  local is_workspace=$(rust_is_workspace "$build_dir" && echo "true" || echo "false")

  # Rust build environment
  cat >> "$dockerfile" <<'EOF'
# Rust build environment
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
EOF

  if [ "$is_workspace" = "true" ]; then
    # Workspace project - copy all Cargo.toml files
    cat >> "$dockerfile" <<'EOF'

# Copy Cargo.toml files for layer caching (workspace)
COPY Cargo.toml Cargo.lock ./
COPY */Cargo.toml ./
EOF
  else
    # Single crate project
    cat >> "$dockerfile" <<'EOF'

# Copy Cargo.toml and Cargo.lock for layer caching
COPY Cargo.toml Cargo.lock* ./
EOF
  fi

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mounts for Cargo registry and build artifacts
    cat >> "$dockerfile" <<EOF

# Create dummy src to build dependencies (layer cached if Cargo.toml unchanged)
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs

# Build dependencies only (cached if Cargo.toml/Cargo.lock unchanged)
RUN --mount=type=cache,id=${cargo_id},target=/usr/local/cargo/registry,sharing=shared \\
    --mount=type=cache,id=${rustbuild_id},target=/build/target,sharing=shared \\
    cargo build --release && rm -rf src

# Copy real source code
COPY . .

# Touch main.rs to ensure it gets rebuilt (dependencies already cached)
RUN touch src/main.rs 2>/dev/null || touch src/lib.rs 2>/dev/null || true
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN --mount=type=cache,id=${cargo_id},target=/usr/local/cargo/registry,sharing=shared \\
    --mount=type=cache,id=${rustbuild_id},target=/build/target,sharing=shared \\
    ${build_command} \\
    && cp target/release/${binary_name} /build/app 2>/dev/null || cp target/release/* /build/ 2>/dev/null || true \\
    && for dir in static public assets templates dist build; do \\
         if [ -d "\$dir" ]; then cp -r "\$dir" /build/; fi; \\
       done \\
    && rm -rf src target Cargo.toml Cargo.lock .git .github 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build release binary
RUN --mount=type=cache,id=${cargo_id},target=/usr/local/cargo/registry,sharing=shared \\
    --mount=type=cache,id=${rustbuild_id},target=/build/target,sharing=shared \\
    cargo build --release \\
    && cp target/release/${binary_name} /build/app \\
    && for dir in static public assets templates dist build; do \\
         if [ -d "\$dir" ]; then cp -r "\$dir" /build/; fi; \\
       done \\
    && rm -rf src target Cargo.toml Cargo.lock .git .github 2>/dev/null; true
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<'EOF'

# Copy source code
COPY . .
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN ${build_command} \\
    && cp target/release/${binary_name} /build/app 2>/dev/null || cp target/release/* /build/ 2>/dev/null || true \\
    && for dir in static public assets templates dist build; do \\
         if [ -d "\$dir" ]; then cp -r "\$dir" /build/; fi; \\
       done \\
    && rm -rf src target Cargo.toml Cargo.lock .git .github 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build release binary
RUN cargo build --release \\
    && cp target/release/${binary_name} /build/app \\
    && for dir in static public assets templates dist build; do \\
         if [ -d "\$dir" ]; then cp -r "\$dir" /build/; fi; \\
       done \\
    && rm -rf src target Cargo.toml Cargo.lock .git .github 2>/dev/null; true
EOF
    fi
  fi
}

# Generate runtime stage base for Rust
# Args: dockerfile_path, runtime_image
rust_generate_runtime_base() {
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

# Copy binary from builder
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
}

# Generate runtime stage environment for Rust
# Args: dockerfile_path, is_dhi_image, dhi_user
rust_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  cat >> "$dockerfile" <<'EOF'

# Rust production environment
ENV RUST_BACKTRACE=1
ENV RUST_LOG=info
EOF
}
