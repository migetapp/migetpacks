#!/bin/bash
# Ruby/Rails build support for migetpacks

# Get Docker images for Ruby builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
ruby_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    # DHI Ruby: -dev for building (has shell/apt), distroless for runtime
    # Libraries are copied from builder to runtime
    BUILD_IMAGE="dhi.io/ruby:${version}-dev"
    RUNTIME_IMAGE="dhi.io/ruby:${version}"
  else
    BUILD_IMAGE="ruby:${version}"
    RUNTIME_IMAGE="ruby:${version}-slim"
  fi
}

# Detect which runtime libraries are needed based on Gemfile/Gemfile.lock
# Sets: RUBY_APT_PACKAGES, RUBY_APT_DEV_PACKAGES, RUBY_NEEDS_* flags
ruby_detect_dependencies() {
  local build_dir="$1"

  RUBY_NEEDS_LIBPQ=false
  RUBY_NEEDS_MYSQL=false
  RUBY_NEEDS_SQLITE=false
  RUBY_NEEDS_NOKOGIRI=false
  RUBY_NEEDS_IMAGEMAGICK=false

  if [ -f "$build_dir/Gemfile" ]; then
    grep -qE "gem ['\"]pg['\"]|gem ['\"]sequel['\"].*pg" "$build_dir/Gemfile" && RUBY_NEEDS_LIBPQ=true
    grep -qiE "gem ['\"]mysql2['\"]|gem ['\"]trilogy['\"]" "$build_dir/Gemfile" && RUBY_NEEDS_MYSQL=true
    grep -qiE "gem ['\"]sqlite3['\"]" "$build_dir/Gemfile" && RUBY_NEEDS_SQLITE=true
    grep -qiE "gem ['\"]nokogiri['\"]|gem ['\"]rails['\"]" "$build_dir/Gemfile" && RUBY_NEEDS_NOKOGIRI=true
    grep -qiE "gem ['\"]mini_magick['\"]|gem ['\"]rmagick['\"]|gem ['\"]image_processing['\"]" "$build_dir/Gemfile" && RUBY_NEEDS_IMAGEMAGICK=true
  fi

  # Check Gemfile.lock for more accurate detection
  if [ -f "$build_dir/Gemfile.lock" ]; then
    grep -qE "^    pg " "$build_dir/Gemfile.lock" && RUBY_NEEDS_LIBPQ=true
    grep -qiE "^    mysql2 |^    trilogy " "$build_dir/Gemfile.lock" && RUBY_NEEDS_MYSQL=true
    grep -qiE "^    sqlite3 " "$build_dir/Gemfile.lock" && RUBY_NEEDS_SQLITE=true
    grep -qiE "^    nokogiri " "$build_dir/Gemfile.lock" && RUBY_NEEDS_NOKOGIRI=true
    grep -qiE "^    mini_magick |^    rmagick |^    image_processing " "$build_dir/Gemfile.lock" && RUBY_NEEDS_IMAGEMAGICK=true
  fi

  # Build runtime apt packages list
  RUBY_APT_PACKAGES=""
  [ "$RUBY_NEEDS_LIBPQ" = true ] && RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES libpq5"
  [ "$RUBY_NEEDS_MYSQL" = true ] && RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES libmariadb3"
  [ "$RUBY_NEEDS_SQLITE" = true ] && RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES libsqlite3-0"
  [ "$RUBY_NEEDS_NOKOGIRI" = true ] && RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES libxml2 libxslt1.1"
  [ "$RUBY_NEEDS_IMAGEMAGICK" = true ] && RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES imagemagick libvips"
  # Always need these
  RUBY_APT_PACKAGES="$RUBY_APT_PACKAGES tzdata ca-certificates"

  # Build dev packages list (for compiling native gems)
  # Base packages needed for most Ruby apps (matches Heroku stack):
  # - pkg-config: locates libraries for native gem compilation
  # - libyaml-dev: psych gem (YAML parser, Rails dependency)
  # - libffi-dev: ffi gem (used by many gems for C bindings)
  # - zlib1g-dev: compression support
  # - libssl-dev: openssl gem and SSL/TLS support
  # - libreadline-dev: readline for IRB/Rails console
  # - libgmp-dev: bigdecimal, bcrypt, and crypto gems
  RUBY_APT_DEV_PACKAGES="pkg-config libyaml-dev libffi-dev zlib1g-dev libssl-dev libreadline-dev libgmp-dev"
  [ "$RUBY_NEEDS_LIBPQ" = true ] && RUBY_APT_DEV_PACKAGES="$RUBY_APT_DEV_PACKAGES libpq-dev"
  [ "$RUBY_NEEDS_MYSQL" = true ] && RUBY_APT_DEV_PACKAGES="$RUBY_APT_DEV_PACKAGES libmariadb-dev"
  [ "$RUBY_NEEDS_SQLITE" = true ] && RUBY_APT_DEV_PACKAGES="$RUBY_APT_DEV_PACKAGES libsqlite3-dev"
  [ "$RUBY_NEEDS_NOKOGIRI" = true ] && RUBY_APT_DEV_PACKAGES="$RUBY_APT_DEV_PACKAGES libxml2-dev libxslt1-dev"
  [ "$RUBY_NEEDS_IMAGEMAGICK" = true ] && RUBY_APT_DEV_PACKAGES="$RUBY_APT_DEV_PACKAGES libmagickwand-dev libvips-dev"
}

# Get bundler version from Gemfile.lock
# Returns: bundler version or empty string
ruby_get_bundler_version() {
  local build_dir="$1"

  if [ -f "$build_dir/Gemfile.lock" ]; then
    grep -A1 "^BUNDLED WITH" "$build_dir/Gemfile.lock" 2>/dev/null | tail -1 | tr -d ' ' || true
  fi
}

# Check if this is a Rails app with assets
ruby_has_rails_assets() {
  local build_dir="$1"

  [ -f "$build_dir/Rakefile" ] && [ -d "$build_dir/app/assets" -o -d "$build_dir/app/javascript" ]
}

# Detect local gem paths from Gemfile (gems with path: option)
# Returns: space-separated list of local gem paths, or empty string
ruby_detect_local_gems() {
  local build_dir="$1"

  if [ -f "$build_dir/Gemfile" ]; then
    # Match: path: "some/path" or path: 'some/path'
    # Extract just the path value using POSIX-compatible sed
    grep -oE "path:[[:space:]]*['\"][^'\"]+['\"]" "$build_dir/Gemfile" 2>/dev/null | \
      sed "s/path:[[:space:]]*['\"]//;s/['\"]$//" | \
      tr '\n' ' ' | sed 's/ $//' || true
  fi
}

# Generate builder stage for Ruby
# Args: dockerfile_path, build_dir, build_command, bundle_without, secondary_lang (deprecated), is_dhi
ruby_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"
  local bundle_without="$4"
  local secondary_lang="$5"
  local is_dhi="$6"

  # Generate SECRET_KEY_BASE for build (needed for asset precompilation)
  local build_secret_key_base
  build_secret_key_base=$(openssl rand -hex 64 2>/dev/null || head -c 64 /dev/urandom | xxd -p | tr -d '\n')

  # Detect dependencies (sets RUBY_APT_PACKAGES and RUBY_APT_DEV_PACKAGES)
  ruby_detect_dependencies "$build_dir"

  # Install git (needed for gems from git repos) and build-essential (needed for native gems)
  if [ "$is_dhi" = true ]; then
    # DHI: install build tools, git, dev packages for native gems, and runtime packages for copying
    cat >> "$dockerfile" <<EOF
# Install build tools, git, and dependencies for native gems (runtime libs copied to distroless)
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ${RUBY_APT_DEV_PACKAGES} ${RUBY_APT_PACKAGES} \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
  else
    # Standard image: install build tools, git, and dev packages for native gems
    cat >> "$dockerfile" <<EOF
# Install build tools, git, and dependencies for native gems
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ${RUBY_APT_DEV_PACKAGES} \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
  fi

  # Get bundler version from Gemfile.lock
  local bundler_version
  bundler_version=$(ruby_get_bundler_version "$build_dir")
  local bundler_install
  if [ -n "$bundler_version" ]; then
    bundler_install="gem install bundler -v '$bundler_version' --no-document"
    info "Using bundler version $bundler_version from Gemfile.lock"
  else
    bundler_install="gem install bundler --no-document"
  fi

  # Check if this is a Rails app with assets
  local has_rails_assets=false
  if ruby_has_rails_assets "$build_dir"; then
    # Skip if sprockets manifest already exists (assets were precompiled locally)
    if ls "$build_dir"/public/assets/.sprockets-manifest-*.json 1>/dev/null 2>&1 || \
       ls "$build_dir"/public/assets/manifest-*.json 1>/dev/null 2>&1; then
      info "Sprockets manifest found, skipping assets:precompile"
    else
      has_rails_assets=true
    fi
  fi

  # Note: Node.js runtime is already copied by buildpack_copy_runtime in bin/build
  # when nodejs is a secondary buildpack (ADDITIONAL_LANGS), so no need to copy here

  # Build bundle without option
  local bundle_without_opt=""
  if [ -n "$bundle_without" ]; then
    bundle_without_opt="bundle config set --local without '${bundle_without}' && "
  fi

  # Cache mount for gem downloads (only when USE_CACHE_MOUNTS is enabled)
  local bundle_mount=""
  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    bundle_mount="--mount=type=cache,target=/root/.bundle/cache,sharing=shared "
  fi

  # Detect local gems (path: references in Gemfile)
  local local_gem_paths
  local_gem_paths=$(ruby_detect_local_gems "$build_dir")

  # Ruby-optimized layer caching: copy Gemfile first, then local gems if any, then bundle install
  # This avoids bind mount which would invalidate cache on any source change
  # Check if Gemfile.lock exists for proper COPY command
  local gemfile_copy="COPY Gemfile Gemfile.lock ./"
  if [ ! -f "$build_dir/Gemfile.lock" ]; then
    gemfile_copy="COPY Gemfile ./"
  fi
  # Include .ruby-version if it exists (Gemfile may reference it via `ruby file: ".ruby-version"`)
  if [ -f "$build_dir/.ruby-version" ]; then
    gemfile_copy="${gemfile_copy}
COPY .ruby-version ./"
  fi

  cat >> "$dockerfile" <<EOF
# Copy Gemfile first for layer caching (bundle install cached if Gemfile unchanged)
${gemfile_copy}
EOF

  # If local gems exist, copy their directories before bundle install
  if [ -n "$local_gem_paths" ]; then
    info "Detected local gems: $local_gem_paths"
    for gem_path in $local_gem_paths; do
      cat >> "$dockerfile" <<EOF
COPY ${gem_path} ./${gem_path}
EOF
    done
  fi

  # Set deployment mode only if Gemfile.lock exists (deployment requires lockfile)
  local deployment_opt=""
  if [ -f "$build_dir/Gemfile.lock" ]; then
    deployment_opt="bundle config set --local deployment 'true' && "
  fi

  cat >> "$dockerfile" <<EOF
ENV GEM_HOME=/build/vendor/bundle
ENV BUNDLE_PATH=/build/vendor/bundle
ENV PATH="/build/vendor/bundle/bin:\$PATH"
# Bundle install (layer cached when Gemfile and local gems unchanged)
RUN ${bundle_mount}mkdir -p /build/vendor/bundle && \\
    ${bundler_install} && \\
    bundle config set --local path '/build/vendor/bundle' && \\
    ${deployment_opt}${bundle_without_opt}bundle install --jobs 4 --retry 3
EOF

  # Install secondary buildpack dependencies BEFORE COPY . . for layer caching
  # Node.js deps are installed here so yarn install is cached when only source changes
  if [ -f "$build_dir/package.json" ]; then
    buildpack_generate_deps "$dockerfile" "nodejs" "$build_dir"
  fi

  cat >> "$dockerfile" <<'EOF'
# Copy rest of source code
COPY . .
RUN rm -rf .bundle/config bin/bundle
EOF

  # Run additional buildpack builds BEFORE assets:precompile (matches Heroku buildpack order)
  # e.g. Node.js heroku-postbuild may set up config needed by Rails asset pipeline
  if [ ${#ADDITIONAL_LANGS[@]} -gt 0 ]; then
    for bp_lang in "${ADDITIONAL_LANGS[@]}"; do
      if [ "$bp_lang" != "$LANG_NORMALIZED" ]; then
        buildpack_generate_build "$dockerfile" "$bp_lang" "$build_dir"
      fi
    done
  fi

  # Use app's RAILS_ENV if set (e.g. from app.json), default to production
  local rails_env="${RAILS_ENV:-production}"

  # Generate dummy DATABASE_URL based on detected DB adapter (matches Heroku behavior)
  local dummy_db_url="postgres://user:pass@127.0.0.1/dummy"
  if [ "$RUBY_NEEDS_MYSQL" = true ]; then
    dummy_db_url="mysql2://user:pass@127.0.0.1/dummy"
  elif [ "$RUBY_NEEDS_SQLITE" = true ]; then
    dummy_db_url="sqlite3:///tmp/dummy.sqlite3"
  fi

  if [ "$has_rails_assets" = true ]; then
    # Rails app with assets - precompile them, then cleanup
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
ENV RAILS_ENV=${rails_env}
ENV RAILS_GROUPS=assets
ENV SECRET_KEY_BASE=${build_secret_key_base}
ENV SECRET_KEY_BASE_DUMMY=1
ENV DATABASE_URL=${dummy_db_url}
RUN ${build_command} && \\
    bundle exec rake assets:precompile && \\
    bundle exec rake assets:clean && \\
    rm -rf .git .github .gitignore test tests spec features .rspec .rubocop* vendor/bundle/ruby/*/cache 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<EOF
ENV RAILS_ENV=${rails_env}
ENV RAILS_GROUPS=assets
ENV SECRET_KEY_BASE=${build_secret_key_base}
ENV SECRET_KEY_BASE_DUMMY=1
ENV DATABASE_URL=${dummy_db_url}
RUN bundle exec rake assets:precompile && \\
    bundle exec rake assets:clean && \\
    rm -rf .git .github .gitignore test tests spec features .rspec .rubocop* vendor/bundle/ruby/*/cache 2>/dev/null; true
EOF
    fi
  else
    # Non-Rails or no assets - still cleanup
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN ${build_command} && \\
    rm -rf .git .github .gitignore test tests spec features .rspec .rubocop* vendor/bundle/ruby/*/cache 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN rm -rf .git .github .gitignore test tests spec features .rspec .rubocop* vendor/bundle/ruby/*/cache 2>/dev/null; true
EOF
    fi
  fi

  # Create runtime directories in builder stage (needed for DHI images which have no shell)
  cat >> "$dockerfile" <<'EOF'
RUN mkdir -p /build/tmp /build/log /build/tmp/pids /build/tmp/cache /build/tmp/sockets
EOF
}

# Generate runtime stage base for Ruby (apt-get install, user creation)
# Args: dockerfile_path, runtime_image, build_dir, is_dhi_image, dhi_user
ruby_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"
  local build_dir="$3"
  local is_dhi_image="$4"
  local dhi_user="$5"

  # Detect dependencies (sets RUBY_NEEDS_* flags)
  ruby_detect_dependencies "$build_dir"

  if [ "$is_dhi_image" = true ]; then
    # DHI distroless runtime - no shell, copy libraries from builder
    cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage (DHI distroless - copy libs from builder)
FROM ${runtime_image}

WORKDIR /app
DOCKERFILE_FOOTER

    # Copy required shared libraries from builder (installed via apt-get in builder)
    if [ "$RUBY_NEEDS_LIBPQ" = true ]; then
      cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/lib/*/libpq.so* /usr/lib/
EOF
    fi
    if [ "$RUBY_NEEDS_MYSQL" = true ]; then
      cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/lib/*/libmariadb.so* /usr/lib/
EOF
    fi
    if [ "$RUBY_NEEDS_SQLITE" = true ]; then
      cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/lib/*/libsqlite3.so* /usr/lib/
EOF
    fi
    if [ "$RUBY_NEEDS_NOKOGIRI" = true ]; then
      cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/lib/*/libxml2.so* /usr/lib/
COPY --from=builder /usr/lib/*/libxslt.so* /usr/lib/
COPY --from=builder /usr/lib/*/libexslt.so* /usr/lib/
EOF
    fi
    if [ "$RUBY_NEEDS_IMAGEMAGICK" = true ]; then
      cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/lib/*/libMagick*.so* /usr/lib/
COPY --from=builder /usr/lib/*/libvips*.so* /usr/lib/
COPY --from=builder /usr/lib/*/ImageMagick* /usr/lib/
COPY --from=builder /etc/ImageMagick* /etc/
EOF
    fi
    # Always copy timezone data and CA certificates
    cat >> "$dockerfile" <<'EOF'
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs /etc/ssl/certs
EOF

    # Copy application from builder
    cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Copy application from builder (directories already created in builder stage)
COPY --from=builder --chown=${dhi_user}:${dhi_user} /build /app
DOCKERFILE_FOOTER
  else
    # Standard image - needs apt-get and user creation
    cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage
FROM ${runtime_image}

# Create non-root user with home directory
RUN getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 miget; \\
    getent passwd 1000 >/dev/null 2>&1 || useradd -u 1000 -g 1000 -m miget; \\
    mkdir -p /home/miget && chown 1000:1000 /home/miget

# Install runtime dependencies BEFORE copying app (for layer caching)
RUN apt-get update && apt-get install -y --no-install-recommends ${RUBY_APT_PACKAGES} \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application from builder
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
  fi
}

# Generate runtime stage environment for Ruby
# Args: dockerfile_path, is_dhi_image, dhi_user, bundle_without, secret_key_base, bundler_version
ruby_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"
  local bundle_without="$4"
  local secret_key_base="$5"
  local bundler_version="$6"

  # Generate SECRET_KEY_BASE if not provided
  if [ -z "$secret_key_base" ]; then
    secret_key_base=$(openssl rand -hex 64 2>/dev/null || head -c 64 /dev/urandom | xxd -p | tr -d '\n')
  fi

  if [ "$is_dhi_image" = true ]; then
    # DHI distroless - no shell commands, directories already created in builder
    cat >> "$dockerfile" <<EOF

# Ruby environment (gems already copied with app from builder)
ENV GEM_HOME=/app/vendor/bundle
ENV BUNDLE_PATH=/app/vendor/bundle
ENV BUNDLE_WITHOUT="${bundle_without}"
ENV PATH="/app/bin:/app/vendor/bundle/bin:\$PATH"
ENV HOME=/home/${dhi_user}
EOF
    # Set BUNDLER_VERSION to prevent auto-switching (exec fails without /usr/bin/env in distroless)
    if [ -n "$bundler_version" ]; then
      cat >> "$dockerfile" <<EOF
ENV BUNDLER_VERSION=${bundler_version}
EOF
    fi
    cat >> "$dockerfile" <<EOF

# Rails environment defaults
ENV LANG=en_US.UTF-8
ENV RACK_ENV=production
ENV RAILS_ENV=production
ENV RAILS_SERVE_STATIC_FILES=enabled
ENV RAILS_LOG_TO_STDOUT=enabled
ENV SECRET_KEY_BASE=${secret_key_base}
ENV MALLOC_ARENA_MAX=2
ENV DISABLE_SPRING=1
ENV PUMA_PERSISTENT_TIMEOUT=95

# Switch to non-root user (directories already created in builder stage)
USER ${dhi_user}
EOF
  else
    cat >> "$dockerfile" <<EOF

# Ruby environment (app already copied from builder)
ENV GEM_HOME=/app/vendor/bundle
ENV BUNDLE_PATH=/app/vendor/bundle
ENV BUNDLE_WITHOUT="${bundle_without}"
ENV PATH="/app/bin:/app/vendor/bundle/bin:\$PATH"
ENV HOME=/home/miget

# Rails environment defaults
ENV LANG=en_US.UTF-8
ENV RACK_ENV=production
ENV RAILS_ENV=production
ENV RAILS_SERVE_STATIC_FILES=enabled
ENV RAILS_LOG_TO_STDOUT=enabled
ENV SECRET_KEY_BASE=${secret_key_base}
ENV MALLOC_ARENA_MAX=2
ENV DISABLE_SPRING=1
ENV PUMA_PERSISTENT_TIMEOUT=95

# Switch to non-root user (directories already created in builder stage)
USER 1000
EOF
  fi
}
