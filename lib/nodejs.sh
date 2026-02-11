#!/bin/bash
# Node.js build support for migetpacks

# Detect package manager from lockfiles and package.json
# Sets: NODEJS_PKG_MANAGER (npm, yarn, pnpm)
# Sets: NODEJS_MULTIPLE_LOCKFILES (true if multiple lockfiles found)
nodejs_detect_pkg_manager() {
  local build_dir="$1"
  NODEJS_PKG_MANAGER=""
  NODEJS_MULTIPLE_LOCKFILES=""

  # Count lockfiles to detect conflicts
  local lockfile_count=0
  [ -f "$build_dir/package-lock.json" ] && lockfile_count=$((lockfile_count + 1))
  [ -f "$build_dir/yarn.lock" ] && lockfile_count=$((lockfile_count + 1))
  [ -f "$build_dir/pnpm-lock.yaml" ] && lockfile_count=$((lockfile_count + 1))

  if [ "$lockfile_count" -gt 1 ]; then
    NODEJS_MULTIPLE_LOCKFILES="true"
  fi

  # Check lockfiles first (most reliable) - priority: pnpm > yarn > npm
  if [ -f "$build_dir/pnpm-lock.yaml" ]; then
    NODEJS_PKG_MANAGER="pnpm"
  elif [ -f "$build_dir/yarn.lock" ]; then
    NODEJS_PKG_MANAGER="yarn"
  elif [ -f "$build_dir/package-lock.json" ]; then
    NODEJS_PKG_MANAGER="npm"
  elif [ -f "$build_dir/package.json" ]; then
    # Check packageManager field in package.json (Corepack)
    local pkg_manager=$(grep -oE '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$build_dir/package.json" 2>/dev/null | head -1)
    if [ -n "$pkg_manager" ]; then
      if echo "$pkg_manager" | grep -q "pnpm"; then
        NODEJS_PKG_MANAGER="pnpm"
      elif echo "$pkg_manager" | grep -q "yarn"; then
        NODEJS_PKG_MANAGER="yarn"
      else
        NODEJS_PKG_MANAGER="npm"
      fi
    else
      NODEJS_PKG_MANAGER="npm"
    fi
  fi
}

# Get Docker images for Node.js builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
nodejs_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/node:${version}-dev"
    RUNTIME_IMAGE="dhi.io/node:${version}"
  else
    BUILD_IMAGE="node:${version}"
    RUNTIME_IMAGE="node:${version}-slim"
  fi
}

# Generate builder stage for Node.js
# Args: dockerfile_path, build_dir, build_command, s3_cache_bucket, cache_key
nodejs_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"
  local s3_cache_bucket="$4"
  local cache_key="$5"

  # Get per-app cache IDs for BuildKit PVC cache
  local npm_id=$(get_cache_id npm)
  local yarn_id=$(get_cache_id yarn)
  local pnpm_id=$(get_cache_id pnpm)

  # Node.js-optimized layer caching: copy lockfiles first, npm install, then copy rest
  # This ensures npm install layer is cached when only source code changes (not package.json)
  local node_options="${NODE_OPTIONS:---max_old_space_size=2560}"
  cat >> "$dockerfile" <<EOF
# Copy package files first for layer caching (npm install cached if lockfiles unchanged)
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
ENV NODE_ENV=production
ENV NPM_CONFIG_LOGLEVEL=error
ENV NODE_VERBOSE=false
ENV NODE_OPTIONS="${node_options}"
EOF

  if [ -n "$s3_cache_bucket" ] && [ -n "$cache_key" ]; then
    # S3 + BuildKit PVC mode: restore S3 cache, install, save cache
    cat >> "$dockerfile" <<'EOF'
# Restore package cache from S3 (if available)
COPY .package-cache/npm/ /tmp/s3-npm-cache/
COPY .package-cache/yarn/ /tmp/s3-yarn-cache/
COPY .package-cache/pnpm/ /tmp/s3-pnpm-cache/
EOF
    # npm install layer (cached if package files unchanged)
    # Only use BuildKit cache mounts when USE_CACHE_MOUNTS is enabled (requires persistent storage)
    if [ "$USE_CACHE_MOUNTS" = "true" ]; then
      cat >> "$dockerfile" <<EOF
RUN --mount=type=cache,id=${npm_id},target=/tmp/buildkit-npm,sharing=shared \\
    --mount=type=cache,id=${yarn_id},target=/tmp/buildkit-yarn,sharing=shared \\
    --mount=type=cache,id=${pnpm_id},target=/tmp/buildkit-pnpm,sharing=shared \\
    mkdir -p /root/.npm /root/.yarn /root/.pnpm-store \\
    && (cp -rn /tmp/s3-npm-cache/* /tmp/buildkit-npm/ 2>/dev/null || true) \\
    && (cp -rn /tmp/s3-yarn-cache/* /tmp/buildkit-yarn/ 2>/dev/null || true) \\
    && (cp -rn /tmp/s3-pnpm-cache/* /tmp/buildkit-pnpm/ 2>/dev/null || true) \\
    && cp -r /tmp/buildkit-npm/* /root/.npm/ 2>/dev/null || true \\
    && cp -r /tmp/buildkit-yarn/* /root/.yarn/ 2>/dev/null || true \\
    && cp -r /tmp/buildkit-pnpm/* /root/.pnpm-store/ 2>/dev/null || true \\
    && if [ -f package-lock.json ]; then npm ci || npm install; \\
       elif [ -f yarn.lock ]; then (command -v yarn || npm install -g yarn) && (yarn install --frozen-lockfile || yarn install); \\
       elif [ -f pnpm-lock.yaml ]; then (command -v pnpm || npm install -g pnpm) && (pnpm install --frozen-lockfile || pnpm install); \\
       else npm install; fi \\
    && cp -r /root/.npm/* /tmp/buildkit-npm/ 2>/dev/null || true \\
    && cp -r /root/.yarn/* /tmp/buildkit-yarn/ 2>/dev/null || true \\
    && cp -r /root/.pnpm-store/* /tmp/buildkit-pnpm/ 2>/dev/null || true

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    else
      # No cache mounts - install without persistent cache
      cat >> "$dockerfile" <<'EOF'
RUN mkdir -p /root/.npm /root/.yarn /root/.pnpm-store \
    && (cp -rn /tmp/s3-npm-cache/* /root/.npm/ 2>/dev/null || true) \
    && (cp -rn /tmp/s3-yarn-cache/* /root/.yarn/ 2>/dev/null || true) \
    && (cp -rn /tmp/s3-pnpm-cache/* /root/.pnpm-store/ 2>/dev/null || true) \
    && if [ -f package-lock.json ]; then npm ci || npm install; \
       elif [ -f yarn.lock ]; then (command -v yarn || npm install -g yarn) && (yarn install --frozen-lockfile || yarn install); \
       elif [ -f pnpm-lock.yaml ]; then (command -v pnpm || npm install -g pnpm) && (pnpm install --frozen-lockfile || pnpm install); \
       else npm install; fi

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    fi
    # Build, prune, and cleanup layer
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN ${build_command} \\
    && if [ -f package-lock.json ]; then npm prune --production; \\
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \\
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \\
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN if grep -q '"heroku-postbuild"' package.json 2>/dev/null; then npm run heroku-postbuild; \
    elif grep -q '"build"' package.json 2>/dev/null; then npm run build; fi \
    && if [ -f package-lock.json ]; then npm prune --production; \
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    fi
    # Save cache for S3 upload
    cat >> "$dockerfile" <<'EOF'
# Save package cache for S3 upload
RUN mkdir -p /cache/npm /cache/yarn /cache/pnpm \
    && cp -r /root/.npm/* /cache/npm/ 2>/dev/null || true \
    && cp -r /root/.yarn/* /cache/yarn/ 2>/dev/null || true \
    && cp -r /root/.pnpm-store/* /cache/pnpm/ 2>/dev/null || true
EOF
  elif [ "$USE_CACHE_MOUNTS" = "true" ]; then
    # BuildKit PVC only mode (simple, direct cache mounts)
    # npm install layer (cached if package files unchanged)
    cat >> "$dockerfile" <<EOF
RUN --mount=type=cache,id=${npm_id},target=/root/.npm,sharing=shared \\
    --mount=type=cache,id=${yarn_id},target=/root/.yarn,sharing=shared \\
    --mount=type=cache,id=${pnpm_id},target=/root/.pnpm-store,sharing=shared \\
    if [ -f package-lock.json ]; then npm ci || npm install; \\
    elif [ -f yarn.lock ]; then (command -v yarn || npm install -g yarn) && (yarn install --frozen-lockfile || yarn install); \\
    elif [ -f pnpm-lock.yaml ]; then (command -v pnpm || npm install -g pnpm) && (pnpm install --frozen-lockfile || pnpm install); \\
    else npm install; fi

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    # Build, prune, and cleanup layer
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN ${build_command} \\
    && if [ -f package-lock.json ]; then npm prune --production; \\
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \\
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \\
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN if grep -q '"heroku-postbuild"' package.json 2>/dev/null; then npm run heroku-postbuild; \
    elif grep -q '"build"' package.json 2>/dev/null; then npm run build; fi \
    && if [ -f package-lock.json ]; then npm prune --production; \
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    fi
  else
    # No cache mounts available - install without persistent cache
    cat >> "$dockerfile" <<'EOF'
RUN if [ -f package-lock.json ]; then npm ci || npm install; \
    elif [ -f yarn.lock ]; then (command -v yarn || npm install -g yarn) && (yarn install --frozen-lockfile || yarn install); \
    elif [ -f pnpm-lock.yaml ]; then (command -v pnpm || npm install -g pnpm) && (pnpm install --frozen-lockfile || pnpm install); \
    else npm install; fi

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    # Build, prune, and cleanup layer
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN ${build_command} \\
    && if [ -f package-lock.json ]; then npm prune --production; \\
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \\
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \\
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN if grep -q '"heroku-postbuild"' package.json 2>/dev/null; then npm run heroku-postbuild; \
    elif grep -q '"build"' package.json 2>/dev/null; then npm run build; fi \
    && if [ -f package-lock.json ]; then npm prune --production; \
       elif [ -f yarn.lock ]; then yarn install --production --frozen-lockfile --ignore-scripts; \
       elif [ -f pnpm-lock.yaml ]; then pnpm prune --prod; fi \
    && rm -rf .git .github .gitignore test tests spec __tests__ coverage .nyc_output .cache 2>/dev/null; true
EOF
    fi
  fi
}

# Generate runtime stage for Node.js
# Args: dockerfile_path
nodejs_generate_runtime() {
  local dockerfile="$1"

  cat >> "$dockerfile" <<'EOF'

# Node.js production environment
ENV NODE_ENV=production
ENV NPM_CONFIG_LOGLEVEL=error
EOF
}
