#!/bin/bash
# Bun build support for migetpacks

# Get Docker images for Bun builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
bun_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/bun:${version}-dev"
    RUNTIME_IMAGE="dhi.io/bun:${version}"
  else
    BUILD_IMAGE="oven/bun:${version}"
    RUNTIME_IMAGE="oven/bun:${version}-slim"
  fi
}

# Detect entry point from package.json scripts.start or common patterns
# Returns: index.ts, server.ts, src/index.ts, etc.
bun_detect_entrypoint() {
  local build_dir="$1"

  # Check package.json scripts.start for entry point
  if [ -f "$build_dir/package.json" ]; then
    local start_script=$(jq -r '.scripts.start // empty' "$build_dir/package.json" 2>/dev/null)
    if [ -n "$start_script" ]; then
      # Extract .ts/.js file from start command (e.g., "bun run index.ts" -> "index.ts")
      local entrypoint=$(echo "$start_script" | grep -oE '[a-zA-Z0-9_/-]+\.(ts|tsx|js|mjs)' | head -1)
      if [ -n "$entrypoint" ] && [ -f "$build_dir/$entrypoint" ]; then
        echo "$entrypoint"
        return
      fi
    fi
  fi

  # Fall back to common entry point patterns
  for file in index.ts server.ts app.ts main.ts src/index.ts src/server.ts index.js server.js; do
    if [ -f "$build_dir/$file" ]; then
      echo "$file"
      return
    fi
  done

  # Default to index.ts
  echo "index.ts"
}

# Check if package.json has a build script
bun_has_build_script() {
  local build_dir="$1"

  if [ -f "$build_dir/package.json" ]; then
    jq -e '.scripts.build' "$build_dir/package.json" >/dev/null 2>&1
  else
    return 1
  fi
}

# Generate builder stage for Bun
# Args: dockerfile_path, build_dir, build_command
bun_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache ID for BuildKit PVC cache
  local bun_id=$(get_cache_id bun)

  # Detect entry point
  local entrypoint=$(bun_detect_entrypoint "$build_dir")
  info "Detected Bun entry point: $entrypoint"

  # Check for build script
  local has_build=$(bun_has_build_script "$build_dir" && echo "true" || echo "false")

  # Detect lockfile type (bun.lockb is binary, bun.lock is text)
  local lockfile="bun.lockb"
  if [ -f "$build_dir/bun.lock" ]; then
    lockfile="bun.lock"
  fi

  # Copy dependency files first for layer caching
  cat >> "$dockerfile" <<EOF

# Copy dependency files for layer caching
COPY package.json ${lockfile}* ./
EOF

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mount for Bun cache
    cat >> "$dockerfile" <<EOF

# Install dependencies (cached if package.json/lockfile unchanged)
RUN --mount=type=cache,id=${bun_id},target=/root/.bun/install/cache,sharing=shared \\
    bun install

# Copy source code
COPY . .
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN ${build_command}
EOF
    elif [ "$has_build" = "true" ]; then
      cat >> "$dockerfile" <<'EOF'

# Run build script
RUN bun run build
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<'EOF'

# Install dependencies
RUN bun install

# Copy source code
COPY . .
EOF

    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Build with custom command
RUN ${build_command}
EOF
    elif [ "$has_build" = "true" ]; then
      cat >> "$dockerfile" <<'EOF'

# Run build script
RUN bun run build
EOF
    fi
  fi
}

# Generate runtime stage for Bun
# Args: dockerfile_path
bun_generate_runtime() {
  local dockerfile="$1"
  # Bun uses default locations, no special env vars needed
  :
}
