#!/bin/bash
# Deno build support for migetpacks

# Get Docker images for Deno builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
deno_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/deno:${version}"
    RUNTIME_IMAGE="dhi.io/deno:${version}"
  else
    BUILD_IMAGE="denoland/deno:${version}"
    RUNTIME_IMAGE="denoland/deno:${version}"
  fi
}

# Detect entry point from deno.json or common patterns
# Returns: main.ts, mod.ts, server.ts, etc.
deno_detect_entrypoint() {
  local build_dir="$1"

  # Check deno.json common task names for entry point
  if [ -f "$build_dir/deno.json" ]; then
    local task_name task_line entrypoint
    for task_name in start run dev serve prod; do
      task_line=$(grep -E "\"${task_name}\"[[:space:]]*:" "$build_dir/deno.json" | head -1)
      [ -z "$task_line" ] && continue
      entrypoint=$(echo "$task_line" | grep -oE '[a-zA-Z0-9_/-]+\.(ts|tsx|js|mts)' | head -1)
      if [ -n "$entrypoint" ] && [ -f "$build_dir/$entrypoint" ]; then
        echo "$entrypoint"
        return
      fi
    done
  fi

  # Fall back to common entry point patterns
  for file in main.ts mod.ts server.ts app.ts index.ts index.js main.js src/main.ts src/mod.ts; do
    if [ -f "$build_dir/$file" ]; then
      echo "$file"
      return
    fi
  done

  # Default to main.ts (may not exist; deno_generate_builder guards the cache step)
  echo "main.ts"
}

# Check if deno.json has imports (dependencies)
deno_has_imports() {
  local build_dir="$1"

  if [ -f "$build_dir/deno.json" ]; then
    grep -qE '"imports"' "$build_dir/deno.json"
  else
    return 1
  fi
}

# Generate builder stage for Deno
# Args: dockerfile_path, build_dir, build_command
# Note: Deno doesn't use BuildKit cache mounts - deps are cached in image layer
deno_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Detect entry point
  local entrypoint=$(deno_detect_entrypoint "$build_dir")
  info "Detected Deno entry point: $entrypoint"

  # Check for imports in deno.json
  local has_imports=$(deno_has_imports "$build_dir" && echo "true" || echo "false")

  # Set DENO_DIR to a location inside /build so it gets copied to runtime
  cat >> "$dockerfile" <<'EOF'

# Set Deno cache inside build dir (will be copied to runtime as /app/.deno-cache)
ENV DENO_DIR=/build/.deno-cache
EOF

  # Copy dependency files first for layer caching
  if [ -f "$build_dir/deno.json" ]; then
    cat >> "$dockerfile" <<'EOF'

# Copy dependency files for layer caching
COPY deno.json deno.lock* ./
EOF

    # Install dependencies (cached in image layer if deno.json unchanged)
    if [ "$has_imports" = "true" ]; then
      cat >> "$dockerfile" <<'EOF'

# Install dependencies
RUN deno install
EOF
    fi
  fi

  cat >> "$dockerfile" <<'EOF'

# Copy source code
COPY . .
EOF

  if [ -n "$build_command" ]; then
    cat >> "$dockerfile" <<EOF

# Build with custom command
RUN ${build_command}
EOF
  elif [ -f "$build_dir/$entrypoint" ]; then
    cat >> "$dockerfile" <<EOF

# Cache dependencies and compile entry point
RUN deno cache ${entrypoint}
EOF
  else
    info "Skipping 'deno cache' — entry point '${entrypoint}' not found in build dir"
  fi
}

# Generate runtime stage for Deno
# Args: dockerfile_path
deno_generate_runtime() {
  local dockerfile="$1"
  # Point to the cache copied from builder stage (at /app/.deno-cache)
  cat >> "$dockerfile" <<'EOF'

# Use Deno cache copied from builder (dependencies pre-cached)
ENV DENO_DIR=/app/.deno-cache
EOF
}
