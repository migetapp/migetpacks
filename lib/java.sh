#!/bin/bash
# Java (Maven/Gradle) build support for migetpacks

# Get Docker images for Java builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
java_get_images() {
  local version="$1"
  local use_dhi="$2"
  local build_tool="$3"  # "maven" or "gradle"

  if [ "$use_dhi" = "true" ]; then
    # DHI uses eclipse-temurin JDK for build, distroless JRE for runtime
    # Note: Build tools (Maven/Gradle) must be installed separately
    BUILD_IMAGE="dhi.io/eclipse-temurin:${version}-jdk-dev"
    RUNTIME_IMAGE="dhi.io/eclipse-temurin:${version}"
  else
    if [ "$build_tool" = "gradle" ]; then
      BUILD_IMAGE="gradle:jdk${version}"
    else
      BUILD_IMAGE="maven:3-eclipse-temurin-${version}"
    fi
    RUNTIME_IMAGE="eclipse-temurin:${version}-jre"
  fi
}

# Detect build tool (Maven or Gradle)
# Returns: "maven" or "gradle"
java_detect_build_tool() {
  local build_dir="$1"

  if [ -f "$build_dir/pom.xml" ]; then
    echo "maven"
  elif [ -f "$build_dir/build.gradle" ] || [ -f "$build_dir/build.gradle.kts" ]; then
    echo "gradle"
  else
    echo "maven"  # default
  fi
}

# Generate builder stage for Java (Maven/Gradle)
# Args: dockerfile_path, build_dir, build_command, is_dhi
java_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"
  local is_dhi="$4"

  local build_tool
  build_tool=$(java_detect_build_tool "$build_dir")

  # Get per-app cache IDs for BuildKit PVC cache
  local maven_id=$(get_cache_id maven)
  local gradle_id=$(get_cache_id gradle)

  # For DHI: install Maven or Gradle (eclipse-temurin JDK doesn't include build tools)
  if [ "$is_dhi" = "true" ]; then
    if [ "$build_tool" = "gradle" ]; then
      cat >> "$dockerfile" <<'EOF'
# Install Gradle (DHI eclipse-temurin only has JDK, not build tools)
RUN apt-get update && apt-get install -y --no-install-recommends gradle \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
    else
      cat >> "$dockerfile" <<'EOF'
# Install Maven (DHI eclipse-temurin only has JDK, not build tools)
RUN apt-get update && apt-get install -y --no-install-recommends maven \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
    fi
  fi

  # Java build environment
  cat >> "$dockerfile" <<'EOF'
# Java build environment
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
EOF

  if [ "$build_tool" = "maven" ]; then
    # Maven: copy pom.xml first for layer caching
    cat >> "$dockerfile" <<'EOF'

# Copy pom.xml for layer caching (dependencies cached if pom.xml unchanged)
COPY pom.xml ./
EOF

    if [ "$USE_CACHE_MOUNTS" = "true" ]; then
      # BuildKit cache mount for Maven
      cat >> "$dockerfile" <<EOF

# Download dependencies using system maven (cached if pom.xml unchanged)
RUN --mount=type=cache,id=${maven_id},target=/root/.m2/repository,sharing=shared \\
    mvn dependency:go-offline -B || true

# Copy rest of source code
COPY . .
EOF
      if [ -n "$build_command" ]; then
        cat >> "$dockerfile" <<EOF

RUN --mount=type=cache,id=${maven_id},target=/root/.m2/repository,sharing=shared \\
    ${build_command} \\
    && rm -rf .git .github .gitignore src/ .mvn/ mvnw* pom.xml 2>/dev/null; true
EOF
      else
        cat >> "$dockerfile" <<EOF

# Build and cleanup source files (use system maven for consistency)
RUN --mount=type=cache,id=${maven_id},target=/root/.m2/repository,sharing=shared \\
    mvn package -DskipTests -B \\
    && rm -rf .git .github .gitignore src/ .mvn/ mvnw* pom.xml 2>/dev/null; true
EOF
      fi
    else
      # No cache mounts
      cat >> "$dockerfile" <<'EOF'

# Download dependencies using system maven
RUN mvn dependency:go-offline -B || true

# Copy rest of source code
COPY . .
EOF
      if [ -n "$build_command" ]; then
        cat >> "$dockerfile" <<EOF

RUN ${build_command} \\
    && rm -rf .git .github .gitignore src/ .mvn/ mvnw* pom.xml 2>/dev/null; true
EOF
      else
        cat >> "$dockerfile" <<'EOF'

# Build and cleanup source files (use system maven for consistency)
RUN mvn package -DskipTests -B \
    && rm -rf .git .github .gitignore src/ .mvn/ mvnw* pom.xml 2>/dev/null; true
EOF
      fi
    fi
  else
    # Gradle: detect if gradlew exists (use wrapper for correct Gradle version)
    local gradle_cmd="gradle"
    if [ -f "$build_dir/gradlew" ]; then
      gradle_cmd="./gradlew"
      info "Using Gradle Wrapper (gradlew)"
    fi

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
  fi

  # For DHI: copy jar to known location (distroless can't expand globs)
  if [ "$is_dhi" = "true" ]; then
    cat >> "$dockerfile" <<'EOF'

# Copy jar to known location for DHI (distroless has no shell to expand globs)
RUN JAR=$(find target build/libs -maxdepth 1 -name "*.jar" \
    ! -name "*-sources.jar" ! -name "*-javadoc.jar" ! -name "*-tests.jar" \
    ! -name "*-plain.jar" ! -name "original-*.jar" 2>/dev/null | head -1) && \
    if [ -n "$JAR" ]; then cp "$JAR" app.jar; fi
EOF
  fi
}

# Generate runtime stage base for Java
# Args: dockerfile_path, runtime_image, is_dhi_image, dhi_user
java_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"
  local is_dhi_image="$3"
  local dhi_user="$4"

  if [ "$is_dhi_image" = true ]; then
    # DHI distroless runtime - no shell, no user creation needed
    cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage (DHI distroless)
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

# Generate runtime stage environment for Java
# Args: dockerfile_path, is_dhi_image, dhi_user
java_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  if [ "$is_dhi_image" = true ]; then
    cat >> "$dockerfile" <<EOF

# Java production environment
ENV JAVA_OPTS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=80.0"
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
ENV HOME=/home/${dhi_user}

# Switch to non-root user
USER ${dhi_user}
EOF
  else
    cat >> "$dockerfile" <<'EOF'

# Java production environment
ENV JAVA_OPTS="-Dfile.encoding=UTF-8 -XX:MaxRAMPercentage=80.0"
ENV JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"
ENV HOME=/home/miget

# Switch to non-root user
USER 1000
EOF
  fi
}
