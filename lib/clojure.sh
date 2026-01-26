#!/bin/bash
# Clojure (Leiningen) build support for migetpacks

# Get Docker images for Clojure builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
clojure_get_images() {
  local version="$1"
  local use_dhi="$2"
  local build_dir="$3"

  # DHI not available for Clojure
  if [ "$use_dhi" = "true" ]; then
    warning "DHI images not available for Clojure, using official images"
  fi

  # Detect Java major version from system.properties
  local java_major="21"
  if [ -f "$build_dir/system.properties" ]; then
    local detected_java=$(grep -E "^java.runtime.version" "$build_dir/system.properties" | cut -d'=' -f2 | tr -d '[:space:]')
    if [ -n "$detected_java" ]; then
      java_major=$(echo "$detected_java" | cut -d'.' -f1)
    fi
  fi

  BUILD_IMAGE="clojure:temurin-${java_major}-lein"
  RUNTIME_IMAGE="eclipse-temurin:${java_major}-jre"

  # Export for runtime stage
  CLOJURE_JAVA_MAJOR="$java_major"
}

# Detect uberjar name from project.clj
clojure_detect_uberjar_name() {
  local build_dir="$1"

  if [ -f "$build_dir/project.clj" ]; then
    grep -E ':uberjar-name[[:space:]]+"' "$build_dir/project.clj" | \
      sed -E 's/.*:uberjar-name[[:space:]]+"([^"]+)".*/\1/' | head -1
  fi
}

# Generate builder stage for Clojure (Leiningen)
# Args: dockerfile_path, build_dir, build_command
clojure_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache IDs for BuildKit PVC cache
  local lein_id=$(get_cache_id lein)
  local m2_id=$(get_cache_id m2)

  # Detect uberjar name for build task
  local uberjar_name=$(clojure_detect_uberjar_name "$build_dir")
  if [ -n "$uberjar_name" ]; then
    info "Detected uberjar-name: $uberjar_name"
  fi

  # Determine build task
  local build_task="uberjar"
  if [ -n "$uberjar_name" ]; then
    build_task="uberjar"
  fi

  # Clojure build environment
  cat >> "$dockerfile" <<'EOF'
# Clojure build environment
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
ENV LEIN_ROOT=1
EOF

  # Copy project.clj first for layer caching
  cat >> "$dockerfile" <<'EOF'

# Copy project.clj for layer caching (dependencies cached if project.clj unchanged)
COPY project.clj ./
EOF

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mounts for Leiningen/Maven
    cat >> "$dockerfile" <<EOF

# Download dependencies using lein (cached if project.clj unchanged)
RUN --mount=type=cache,id=${lein_id},target=/root/.lein,sharing=shared \\
    --mount=type=cache,id=${m2_id},target=/root/.m2,sharing=shared \\
    lein deps

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN --mount=type=cache,id=${lein_id},target=/root/.lein,sharing=shared \\
    --mount=type=cache,id=${m2_id},target=/root/.m2,sharing=shared \\
    ${build_command} \\
    && rm -rf .git .github .gitignore src/ test/ dev/ resources/public/js/compiled 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build uberjar and cleanup source files
RUN --mount=type=cache,id=${lein_id},target=/root/.lein,sharing=shared \\
    --mount=type=cache,id=${m2_id},target=/root/.m2,sharing=shared \\
    lein ${build_task} \\
    && rm -rf .git .github .gitignore src/ test/ dev/ resources/public/js/compiled 2>/dev/null; true
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<'EOF'

# Download dependencies using lein
RUN lein deps

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN ${build_command} \\
    && rm -rf .git .github .gitignore src/ test/ dev/ resources/public/js/compiled 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build uberjar and cleanup source files
RUN lein ${build_task} \\
    && rm -rf .git .github .gitignore src/ test/ dev/ resources/public/js/compiled 2>/dev/null; true
EOF
    fi
  fi
}

# Generate runtime stage base for Clojure
# Args: dockerfile_path, runtime_image
clojure_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"

  cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage
FROM ${runtime_image}

# Create non-root user with home directory
RUN getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 miget; \\
    getent passwd 1000 >/dev/null 2>&1 || useradd -u 1000 -g 1000 -m miget; \\
    mkdir -p /home/miget && chown 1000:1000 /home/miget

WORKDIR /app

# Copy application from builder (source files already removed)
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
}

# Generate runtime stage environment for Clojure
# Args: dockerfile_path, is_dhi_image, dhi_user
clojure_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  cat >> "$dockerfile" <<'EOF'

# Clojure/JVM production environment
ENV JAVA_OPTS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=80.0 -Dclojure.main.report=stderr"
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
EOF
}
