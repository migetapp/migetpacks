#!/bin/bash
# Kotlin (Gradle) build support for migetpacks

# Get Docker images for Kotlin builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
kotlin_get_images() {
  local use_dhi="$1"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/eclipse-temurin:21-jdk-dev"
    RUNTIME_IMAGE="dhi.io/eclipse-temurin:21"
  else
    BUILD_IMAGE="gradle:jdk21"
    RUNTIME_IMAGE="eclipse-temurin:21-jre"
  fi
}

# Generate builder stage for Kotlin (Gradle)
# Args: dockerfile_path, build_dir, build_command, is_dhi
kotlin_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"
  local is_dhi="$4"

  # Get per-app cache ID for BuildKit PVC cache
  local gradle_id=$(get_cache_id gradle)

  # Detect if gradlew exists (use wrapper for correct Gradle version)
  local gradle_cmd="gradle"
  if [ -f "$build_dir/gradlew" ]; then
    gradle_cmd="./gradlew"
    info "Using Gradle Wrapper (gradlew)"
  fi

  # Kotlin build environment
  cat >> "$dockerfile" <<'EOF'
# Kotlin build environment
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
EOF

  # Copy Gradle build files first for layer caching
  # Include gradle wrapper if present
  if [ -f "$build_dir/gradlew" ]; then
    cat >> "$dockerfile" <<'EOF'

# Copy Gradle wrapper and build files for layer caching
COPY gradlew ./
COPY gradle/ gradle/
COPY build.gradle* settings.gradle* ./
EOF
  else
    cat >> "$dockerfile" <<'EOF'

# Copy Gradle build files for layer caching (dependencies cached if build files unchanged)
COPY build.gradle* settings.gradle* ./
EOF
  fi

  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit cache mount for Gradle
    cat >> "$dockerfile" <<EOF

# Download dependencies using gradle (cached if build files unchanged)
RUN --mount=type=cache,id=${gradle_id},target=/root/.gradle/caches,sharing=shared \\
    --mount=type=cache,id=${gradle_id}-wrapper,target=/root/.gradle/wrapper,sharing=shared \\
    ${gradle_cmd} dependencies --no-daemon || true

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN --mount=type=cache,id=${gradle_id},target=/root/.gradle/caches,sharing=shared \\
    --mount=type=cache,id=${gradle_id}-wrapper,target=/root/.gradle/wrapper,sharing=shared \\
    ${build_command} \\
    && rm -rf .git .github .gitignore src/ gradle/ gradlew* build.gradle* settings.gradle* gradle.properties 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build and cleanup source files
RUN --mount=type=cache,id=${gradle_id},target=/root/.gradle/caches,sharing=shared \\
    --mount=type=cache,id=${gradle_id}-wrapper,target=/root/.gradle/wrapper,sharing=shared \\
    ${gradle_cmd} build -x test --no-daemon \\
    && rm -rf .git .github .gitignore src/ gradle/ gradlew* build.gradle* settings.gradle* gradle.properties 2>/dev/null; true
EOF
    fi
  else
    # No cache mounts
    cat >> "$dockerfile" <<EOF

# Download dependencies using gradle
RUN ${gradle_cmd} dependencies --no-daemon || true

# Copy rest of source code
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN ${build_command} \\
    && rm -rf .git .github .gitignore src/ gradle/ gradlew* build.gradle* settings.gradle* gradle.properties 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF

# Build and cleanup source files
RUN ${gradle_cmd} build -x test --no-daemon \\
    && rm -rf .git .github .gitignore src/ gradle/ gradlew* build.gradle* settings.gradle* gradle.properties 2>/dev/null; true
EOF
    fi
  fi

  # For DHI: copy jar to known location (distroless can't expand globs)
  if [ "$is_dhi" = "true" ]; then
    cat >> "$dockerfile" <<'EOF'

# Copy jar to known location for DHI (distroless has no shell to expand globs)
RUN JAR=$(find build/libs -maxdepth 1 -name "*.jar" \
    ! -name "*-sources.jar" ! -name "*-javadoc.jar" ! -name "*-tests.jar" \
    ! -name "*-plain.jar" ! -name "original-*.jar" 2>/dev/null | head -1) && \
    if [ -n "$JAR" ]; then cp "$JAR" app.jar; fi
EOF
  fi
}

# Generate runtime stage base for Kotlin
# Args: dockerfile_path, runtime_image
kotlin_generate_runtime_base() {
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

# Generate runtime stage environment for Kotlin
# Args: dockerfile_path, is_dhi_image, dhi_user
kotlin_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  cat >> "$dockerfile" <<'EOF'

# Kotlin/JVM production environment
ENV JAVA_OPTS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=80.0"
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
EOF
}
