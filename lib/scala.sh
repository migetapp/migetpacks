#!/bin/bash
# Scala (sbt) build support for migetpacks

# Get Docker images for Scala builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
# Note: Scala uses sbtscala images for build (includes sbt), DHI for runtime
scala_get_images() {
  local version="$1"
  local use_dhi="$2"
  local build_dir="$3"

  # Detect Java major version from system.properties
  local java_major="21"
  if [ -f "$build_dir/system.properties" ]; then
    local detected_java=$(grep -E "^java.runtime.version" "$build_dir/system.properties" | cut -d'=' -f2 | tr -d '[:space:]')
    if [ -n "$detected_java" ]; then
      java_major=$(echo "$detected_java" | cut -d'.' -f1)
    fi
  fi

  # Map Java major version to sbtscala image tag
  local jdk_tag
  case "$java_major" in
    8)  jdk_tag="8u442-b06" ;;
    11) jdk_tag="11.0.26_4" ;;
    17) jdk_tag="17.0.15_6" ;;
    21) jdk_tag="21.0.6_7" ;;
    *)  jdk_tag="21.0.6_7"; java_major="21" ;;
  esac

  # Detect sbt version from project/build.properties
  local sbt_version="1.12.0"
  if [ -f "$build_dir/project/build.properties" ]; then
    local detected_sbt=$(grep -E "^sbt.version" "$build_dir/project/build.properties" | cut -d'=' -f2 | tr -d '[:space:]')
    if [ -n "$detected_sbt" ]; then
      sbt_version="$detected_sbt"
    fi
  fi

  # Build: always sbtscala official image (includes sbt tools)
  BUILD_IMAGE="sbtscala/scala-sbt:eclipse-temurin-${jdk_tag}_${sbt_version}_${version}"

  # Runtime: DHI eclipse-temurin or official
  if [ "$use_dhi" = "true" ]; then
    RUNTIME_IMAGE="dhi.io/eclipse-temurin:${java_major}"
  else
    RUNTIME_IMAGE="eclipse-temurin:${java_major}-jre"
  fi

  # Export for runtime stage
  SCALA_JAVA_MAJOR="$java_major"
}

# Detect sbt version from project
# Returns: sbt version or empty
scala_detect_sbt_version() {
  local build_dir="$1"

  if [ -f "$build_dir/project/build.properties" ]; then
    grep -E "^sbt.version" "$build_dir/project/build.properties" | cut -d'=' -f2 | tr -d '[:space:]'
  fi
}

# Detect if Play Framework app
scala_is_play_app() {
  local build_dir="$1"

  if [ -f "$build_dir/build.sbt" ] && grep -q "PlayScala\|PlayJava\|play.sbt.Play" "$build_dir/build.sbt"; then
    echo "true"
  else
    echo "false"
  fi
}

# Detect if sbt-native-packager is used
scala_uses_native_packager() {
  local build_dir="$1"

  if [ -f "$build_dir/project/plugins.sbt" ] && grep -q "sbt-native-packager" "$build_dir/project/plugins.sbt"; then
    echo "true"
  else
    echo "false"
  fi
}

# Generate builder stage for Scala (sbt)
# Args: dockerfile_path, build_dir, build_command
scala_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache IDs for BuildKit PVC cache
  local sbt_id=$(get_cache_id sbt)
  local ivy_id=$(get_cache_id ivy)
  local coursier_id=$(get_cache_id coursier)

  # Detect sbt version
  local sbt_version=$(scala_detect_sbt_version "$build_dir")
  if [ -n "$sbt_version" ]; then
    info "Detected sbt version: $sbt_version"
    # Validate sbt version
    local sbt_major=$(echo "$sbt_version" | cut -d'.' -f1)
    local sbt_minor=$(echo "$sbt_version" | cut -d'.' -f2)
    if [ "$sbt_major" = "0" ] && [ "$sbt_minor" -lt "13" ]; then
      error "sbt version $sbt_version is not supported. Minimum supported version is 0.13.18"
      exit 1
    elif [ "$sbt_major" = "0" ] && [ "$sbt_minor" = "13" ]; then
      warning "sbt 0.13.x is deprecated. Please upgrade to sbt 1.x"
    elif [ "$sbt_major" = "2" ]; then
      warning "sbt 2.x detected - support is experimental"
    fi
  fi

  # Detect Play Framework and native-packager
  local is_play_app=$(scala_is_play_app "$build_dir")
  local uses_native_packager=$(scala_uses_native_packager "$build_dir")

  if [ "$is_play_app" = "true" ]; then
    info "Detected Play Framework application"
  fi
  if [ "$uses_native_packager" = "true" ]; then
    info "Detected sbt-native-packager plugin"
  fi

  # Scala/sbt build environment
  cat >> "$dockerfile" <<'EOF'
# Scala/sbt build environment
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
ENV SBT_OPTS="-Xmx2G -XX:MaxMetaspaceSize=512m"
EOF

  # Copy sbt build files first for layer caching
  cat >> "$dockerfile" <<'EOF'

# Copy sbt build files for layer caching (dependencies cached if build files unchanged)
COPY build.sbt ./
COPY project/ project/
EOF

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mounts for sbt/ivy/coursier
    cat >> "$dockerfile" <<EOF

# Download dependencies using sbt (cached if build files unchanged)
RUN --mount=type=cache,id=${sbt_id},target=/root/.sbt,sharing=shared \\
    --mount=type=cache,id=${ivy_id},target=/root/.ivy2,sharing=shared \\
    --mount=type=cache,id=${coursier_id},target=/root/.cache/coursier,sharing=shared \\
    sbt update || true

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN --mount=type=cache,id=${sbt_id},target=/root/.sbt,sharing=shared \\
    --mount=type=cache,id=${ivy_id},target=/root/.ivy2,sharing=shared \\
    --mount=type=cache,id=${coursier_id},target=/root/.cache/coursier,sharing=shared \\
    ${build_command} \\
    && rm -rf .git .github .gitignore src/ project/ build.sbt 2>/dev/null; true
EOF
    else
      # Default sbt build command
      local sbt_tasks="compile stage"
      if [ "$is_play_app" = "true" ]; then
        sbt_tasks="compile stage"
      elif [ "$uses_native_packager" = "true" ]; then
        sbt_tasks="compile stage"
      else
        sbt_tasks="compile assembly"
      fi

      cat >> "$dockerfile" <<EOF

# Build and cleanup source files
RUN --mount=type=cache,id=${sbt_id},target=/root/.sbt,sharing=shared \\
    --mount=type=cache,id=${ivy_id},target=/root/.ivy2,sharing=shared \\
    --mount=type=cache,id=${coursier_id},target=/root/.cache/coursier,sharing=shared \\
    sbt ${sbt_tasks} \\
    && rm -rf .git .github .gitignore src/ project/ build.sbt 2>/dev/null; true
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<'EOF'

# Download dependencies using sbt
RUN sbt update || true

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN ${build_command} \\
    && rm -rf .git .github .gitignore src/ project/ build.sbt 2>/dev/null; true
EOF
    else
      local sbt_tasks="compile stage"
      if [ "$is_play_app" = "true" ]; then
        sbt_tasks="compile stage"
      elif [ "$uses_native_packager" = "true" ]; then
        sbt_tasks="compile stage"
      else
        sbt_tasks="compile assembly"
      fi

      cat >> "$dockerfile" <<EOF

# Build and cleanup source files
RUN sbt ${sbt_tasks} \\
    && rm -rf .git .github .gitignore src/ project/ build.sbt 2>/dev/null; true
EOF
    fi
  fi
}

# Generate runtime stage base for Scala
# Args: dockerfile_path, runtime_image, is_dhi_image, dhi_user
scala_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"
  local is_dhi_image="$3"
  local dhi_user="${4:-nonroot}"

  if [ "$is_dhi_image" = "true" ]; then
    cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage (Docker Hardened Image - uses ${dhi_user} user)
FROM ${runtime_image}

WORKDIR /app

# Copy application from builder (source files already removed)
COPY --from=builder --chown=${dhi_user}:${dhi_user} /build /app
DOCKERFILE_FOOTER
  else
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
  fi
}

# Generate runtime stage environment for Scala
# Args: dockerfile_path, is_dhi_image, dhi_user
scala_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  cat >> "$dockerfile" <<'EOF'

# Scala/JVM production environment
ENV JAVA_OPTS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=80.0"
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
EOF
}
