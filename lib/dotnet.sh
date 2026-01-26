#!/bin/bash
# .NET build support for migetpacks

# Get Docker images for .NET builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
dotnet_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/dotnet:${version}-sdk"
    RUNTIME_IMAGE="dhi.io/aspnetcore:${version}"
  else
    BUILD_IMAGE="mcr.microsoft.com/dotnet/sdk:${version}"
    RUNTIME_IMAGE="mcr.microsoft.com/dotnet/aspnet:${version}"
  fi
}

# Generate builder stage for .NET with layer caching
# Args: dockerfile_path, build_dir, build_command
dotnet_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Cache mount prefix for NuGet (only when USE_CACHE_MOUNTS is enabled)
  local mount_prefix=""
  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    mount_prefix="--mount=type=cache,target=/root/.nuget/packages,sharing=shared "
  fi

  # .NET build environment variables and layer caching setup
  # Copy all source first, then use multi-stage caching via NuGet cache mount
  cat >> "$dockerfile" <<'EOF'
# .NET build optimizations
ENV NUGET_XMLDOC_MODE=skip
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1

# Copy source code
COPY . .

EOF

  # Build/publish layer with NuGet cache mount
  if [ -n "$build_command" ]; then
    cat >> "$dockerfile" <<EOF
RUN ${mount_prefix}if [ -f .config/dotnet-tools.json ]; then dotnet tool restore; fi \\
    && dotnet restore \\
    && ${build_command}
EOF
  else
    # Publish to bin/publish/ relative to each project
    # Clean up: remove source files and intermediate artifacts, keep only bin/publish/
    cat >> "$dockerfile" <<EOF
RUN ${mount_prefix}if [ -f .config/dotnet-tools.json ]; then dotnet tool restore; fi \\
    && dotnet restore \\
    && dotnet publish --configuration Release --no-restore -p:PublishDir=bin/publish \\
    && find . -path "*/bin/publish/*" -type f ! -name "*.dll" ! -name "*.json" ! -name "*.pdb" -exec chmod +x {} \\; \\
    && rm -rf */obj */*/obj */*/*/obj 2>/dev/null; rm -rf */bin/Release/net* */bin/Debug 2>/dev/null; \\
       find . -maxdepth 3 -type f \\( -name "*.cs" -o -name "*.fs" -o -name "*.vb" -o -name "*.csproj" -o -name "*.fsproj" -o -name "*.vbproj" -o -name "*.sln" -o -name "*.slnx" \\) -delete 2>/dev/null; \\
       rm -rf .git .github .config/dotnet-tools.json 2>/dev/null; true
EOF
  fi
}

# Generate runtime stage base for .NET
# Args: dockerfile_path, runtime_image
dotnet_generate_runtime_base() {
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

# Copy cleaned build output (source files removed in builder)
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
}

# Generate runtime stage environment for .NET
# Args: dockerfile_path, is_dhi_image, dhi_user
dotnet_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"

  cat >> "$dockerfile" <<'EOF'

# .NET production environment
ENV ASPNETCORE_ENVIRONMENT=Production
ENV DOTNET_RUNNING_IN_CONTAINER=true
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV ASPNETCORE_HTTP_PORTS=5000
EOF
}
