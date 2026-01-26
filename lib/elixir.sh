#!/bin/bash
# Elixir/Phoenix build support for migetpacks

# Get Docker images for Elixir builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
elixir_get_images() {
  local version="$1"
  local use_dhi="$2"

  # DHI images not available for Elixir
  if [ "$use_dhi" = "true" ]; then
    warning "DHI images not available for Elixir, using official images"
  fi
  BUILD_IMAGE="elixir:${version}"
  RUNTIME_IMAGE="elixir:${version}-slim"
}

# Detect if this is a Phoenix project
elixir_is_phoenix() {
  local build_dir="$1"

  if [ -f "$build_dir/mix.exs" ]; then
    grep -q ":phoenix" "$build_dir/mix.exs"
  else
    return 1
  fi
}

# Detect if project uses releases
elixir_uses_releases() {
  local build_dir="$1"

  if [ -f "$build_dir/mix.exs" ]; then
    grep -q "releases:" "$build_dir/mix.exs"
  else
    return 1
  fi
}

# Get app name from mix.exs
elixir_detect_app_name() {
  local build_dir="$1"

  if [ -f "$build_dir/mix.exs" ]; then
    grep -E "app:" "$build_dir/mix.exs" | head -1 | sed 's/.*:\([a-z_]*\).*/\1/'
  else
    echo "app"
  fi
}

# Generate builder stage for Elixir
# Args: dockerfile_path, build_dir, build_command, mix_env
elixir_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"
  local mix_env="$4"

  # Get per-app cache IDs for BuildKit PVC cache
  local hex_id=$(get_cache_id hex)
  local mix_id=$(get_cache_id mix)

  # Detect project type
  local is_phoenix=$(elixir_is_phoenix "$build_dir" && echo "true" || echo "false")
  local uses_releases=$(elixir_uses_releases "$build_dir" && echo "true" || echo "false")
  local app_name=$(elixir_detect_app_name "$build_dir")

  if [ "$is_phoenix" = "true" ]; then
    info "Detected Phoenix application"
  fi

  # Elixir build environment
  cat >> "$dockerfile" <<EOF
# Elixir build environment
ENV MIX_ENV=${mix_env}
ENV ERL_FLAGS="-noinput"
ENV HEX_HOME=/root/.hex
ENV MIX_HOME=/root/.mix
EOF

  # Copy dependency files first for layer caching
  cat >> "$dockerfile" <<'EOF'

# Copy dependency files for layer caching
COPY mix.exs mix.lock* ./
EOF

  # For umbrella projects, copy all child mix.exs files
  if [ -d "$build_dir/apps" ]; then
    info "Detected Elixir umbrella project"
    cat >> "$dockerfile" <<'EOF'
COPY apps/*/mix.exs ./apps/
EOF
  fi

  # For Phoenix projects, copy config early (needed for deps.compile)
  if [ "$is_phoenix" = "true" ] && [ -d "$build_dir/config" ]; then
    cat >> "$dockerfile" <<'EOF'
COPY config ./config/
EOF
  fi

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mounts for Hex and Mix deps
    cat >> "$dockerfile" <<EOF

# Install Hex and Rebar, then fetch dependencies (cached if mix.exs/mix.lock unchanged)
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix local.hex --force \\
    && mix local.rebar --force \\
    && mix deps.get --only ${mix_env}

# Compile dependencies (cached separately from app code)
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix deps.compile

# Copy rest of source code
COPY . .
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    ${build_command}
EOF
    elif [ "$is_phoenix" = "true" ]; then
      # Phoenix: compile assets and create digest
      cat >> "$dockerfile" <<EOF

# Compile Elixir code
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix compile

# Compile Phoenix assets (if assets directory exists)
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    if [ -d "assets" ]; then \\
      mix assets.deploy 2>/dev/null || (cd assets && npm install && npm run deploy && cd .. && mix phx.digest); \\
    fi
EOF
      if [ "$uses_releases" = "true" ]; then
        cat >> "$dockerfile" <<EOF

# Build release
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix release
EOF
      fi
    else
      # Plain Elixir project
      cat >> "$dockerfile" <<EOF

# Compile Elixir code
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix compile
EOF
      if [ "$uses_releases" = "true" ]; then
        cat >> "$dockerfile" <<EOF

# Build release
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    mix release
EOF
      fi
    fi

    # Only copy hex/mix if NOT using releases (releases are self-contained)
    if [ "$uses_releases" != "true" ]; then
      cat >> "$dockerfile" <<EOF

# Copy Hex/Mix to build dir for runtime (needed by mix phx.server)
RUN --mount=type=cache,id=${hex_id},target=/root/.hex,sharing=shared \\
    --mount=type=cache,id=${mix_id},target=/root/.mix,sharing=shared \\
    cp -r /root/.hex /build/.hex && cp -r /root/.mix /build/.mix
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<EOF

# Install Hex and Rebar, then fetch dependencies
RUN mix local.hex --force \\
    && mix local.rebar --force \\
    && mix deps.get --only ${mix_env} \\
    && mix deps.compile

# Copy rest of source code
COPY . .
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN ${build_command}
EOF
    elif [ "$is_phoenix" = "true" ]; then
      cat >> "$dockerfile" <<EOF

# Compile Elixir and Phoenix assets
RUN mix compile \\
    && if [ -d "assets" ]; then \\
         mix assets.deploy 2>/dev/null || (cd assets && npm install && npm run deploy && cd .. && mix phx.digest); \\
       fi
EOF
      if [ "$uses_releases" = "true" ]; then
        cat >> "$dockerfile" <<'EOF'

# Build release
RUN mix release
EOF
      fi
    else
      cat >> "$dockerfile" <<'EOF'

# Compile Elixir code
RUN mix compile
EOF
      if [ "$uses_releases" = "true" ]; then
        cat >> "$dockerfile" <<'EOF'

# Build release
RUN mix release
EOF
      fi
    fi

    # Only copy hex/mix if NOT using releases (releases are self-contained)
    if [ "$uses_releases" != "true" ]; then
      cat >> "$dockerfile" <<'EOF'

# Copy Hex/Mix to build dir for runtime (needed by mix phx.server)
RUN cp -r /root/.hex /build/.hex && cp -r /root/.mix /build/.mix
EOF
    fi
  fi
}

# Generate runtime stage for Elixir
# Args: dockerfile_path, mix_env, uses_releases
elixir_generate_runtime() {
  local dockerfile="$1"
  local mix_env="$2"
  local uses_releases="$3"

  cat >> "$dockerfile" <<EOF

# Elixir runtime environment
ENV MIX_ENV=${mix_env}
ENV HOME=/home/miget
EOF

  if [ "$uses_releases" = "true" ]; then
    # Releases are self-contained - no hex/mix needed at runtime
    info "Using Elixir release (no hex/mix needed at runtime)"
  else
    # Without releases, mix phx.server needs hex/mix and git (for git deps verification)
    # Copy from builder (we saved them from cache mount to /build/.hex and /build/.mix)
    cat >> "$dockerfile" <<EOF
ENV HEX_HOME=/home/miget/.hex
ENV MIX_HOME=/home/miget/.mix

# Install git (needed for git dependency verification at runtime)
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

# Copy Hex/Mix from builder (needed by mix phx.server)
RUN mkdir -p /home/miget/.hex /home/miget/.mix
COPY --from=builder --chown=1000:1000 /build/.hex /home/miget/.hex
COPY --from=builder --chown=1000:1000 /build/.mix /home/miget/.mix
EOF
  fi
}
