#!/bin/bash
# Multi-buildpack support with shared environment
# All runtimes are copied into the primary builder, then builds run sequentially

# Get the source image for copying runtime binaries
# Args: language, version, use_dhi
buildpack_get_source_image() {
  local lang="$1"
  local version="$2"
  local use_dhi="$3"

  case "$lang" in
    nodejs|node)
      if [ "$use_dhi" = "true" ]; then
        echo "dhi.io/node:${version}-dev"
      else
        echo "node:${version}"
      fi
      ;;
    python)
      if [ "$use_dhi" = "true" ]; then
        echo "dhi.io/python:${version}-dev"
      else
        echo "python:${version}"
      fi
      ;;
    ruby)
      if [ "$use_dhi" = "true" ]; then
        echo "dhi.io/ruby:${version}-dev"
      else
        echo "ruby:${version}"
      fi
      ;;
    go|golang)
      if [ "$use_dhi" = "true" ]; then
        echo "dhi.io/golang:${version}-dev"
      else
        echo "golang:${version}"
      fi
      ;;
    *)
      echo "${lang}:${version}"
      ;;
  esac
}

# Generate COPY commands to add a runtime to the primary builder
# This copies binaries and libraries from the language image
# Args: dockerfile, language, source_image
buildpack_copy_runtime() {
  local dockerfile="$1"
  local lang="$2"
  local source_image="$3"

  case "$lang" in
    nodejs|node)
      # DHI images use /opt/nodejs structure, standard images use /usr/local
      if [[ "$source_image" == dhi.io/* ]]; then
        cat >> "$dockerfile" <<EOF
# Add Node.js runtime (DHI)
COPY --from=${source_image} /opt/nodejs /opt/nodejs
COPY --from=${source_image} /opt/yarn /opt/yarn
RUN ln -sf /opt/nodejs/*/bin/node /usr/local/bin/node && \\
    ln -sf /opt/nodejs/*/bin/npm /usr/local/bin/npm && \\
    ln -sf /opt/nodejs/*/bin/npx /usr/local/bin/npx && \\
    ln -sf /opt/yarn/*/bin/yarn /usr/local/bin/yarn
ENV PATH="/usr/local/bin:\${PATH}"
EOF
      else
        cat >> "$dockerfile" <<EOF
# Add Node.js runtime
COPY --from=${source_image} /usr/local/bin/node /usr/local/bin/
COPY --from=${source_image} /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \\
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
ENV PATH="/usr/local/bin:\${PATH}"
EOF
      fi
      ;;
    python)
      # Python version for lib path (e.g., 3.11 from 3.11.4)
      local py_minor=$(echo "$source_image" | grep -oE '[0-9]+\.[0-9]+' | head -1)
      cat >> "$dockerfile" <<EOF
# Add Python runtime
COPY --from=${source_image} /usr/local/bin/python* /usr/local/bin/
COPY --from=${source_image} /usr/local/bin/pip* /usr/local/bin/
COPY --from=${source_image} /usr/local/lib/python${py_minor} /usr/local/lib/python${py_minor}
COPY --from=${source_image} /usr/local/lib/libpython* /usr/local/lib/
RUN ldconfig 2>/dev/null || true
ENV PATH="/usr/local/bin:\${PATH}"
ENV PYTHONPATH="/usr/local/lib/python${py_minor}/site-packages"
EOF
      ;;
    ruby)
      cat >> "$dockerfile" <<EOF
# Add Ruby runtime
COPY --from=${source_image} /usr/local/bin/ruby /usr/local/bin/
COPY --from=${source_image} /usr/local/bin/gem /usr/local/bin/
COPY --from=${source_image} /usr/local/bin/bundle* /usr/local/bin/
COPY --from=${source_image} /usr/local/lib/ruby /usr/local/lib/ruby
COPY --from=${source_image} /usr/local/lib/libruby* /usr/local/lib/
RUN ldconfig 2>/dev/null || true
ENV PATH="/usr/local/bin:\${PATH}"
ENV GEM_HOME="/usr/local/lib/ruby/gems"
EOF
      ;;
    go|golang)
      cat >> "$dockerfile" <<EOF
# Add Go runtime
COPY --from=${source_image} /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:\${PATH}"
ENV GOPATH="/go"
EOF
      ;;
    *)
      warning "Runtime copy not implemented for: $lang"
      ;;
  esac
}

# Generate dependency install commands for secondary buildpack (called BEFORE COPY . .)
# This enables layer caching for dependencies when only source code changes
# Args: dockerfile, language, build_dir
buildpack_generate_deps() {
  local dockerfile="$1"
  local lang="$2"
  local build_dir="$3"

  case "$lang" in
    nodejs|node)
      # Determine package manager and lockfile
      local lockfile="package-lock.json*"
      local install_cmd="npm ci || npm install"
      local yarn_id=$(get_cache_id yarn)
      local npm_id=$(get_cache_id npm)
      local pnpm_id=$(get_cache_id pnpm)

      if [ -f "$build_dir/pnpm-lock.yaml" ]; then
        lockfile="pnpm-lock.yaml"
        install_cmd="npm install -g pnpm && pnpm install --frozen-lockfile"
      elif [ -f "$build_dir/yarn.lock" ]; then
        lockfile="yarn.lock"
        install_cmd="npm install -g yarn && yarn install --frozen-lockfile"
      fi

      local node_options="${NODE_OPTIONS:---max_old_space_size=2560}"
      cat >> "$dockerfile" <<EOF
# Node.js: environment and lockfiles for layer caching
ENV NODE_OPTIONS="${node_options}"
COPY package.json ${lockfile} ./
EOF
      if [ "$USE_CACHE_MOUNTS" = "true" ]; then
        cat >> "$dockerfile" <<EOF
RUN --mount=type=cache,id=${npm_id},target=/root/.npm,sharing=shared \\
    --mount=type=cache,id=${yarn_id},target=/root/.yarn,sharing=shared \\
    --mount=type=cache,id=${pnpm_id},target=/root/.pnpm-store,sharing=shared \\
    ${install_cmd}
EOF
      else
        cat >> "$dockerfile" <<EOF
RUN ${install_cmd}
EOF
      fi
      ;;
  esac
}

# Generate build commands for an additional buildpack (called AFTER COPY . .)
# Args: dockerfile, language, build_dir
buildpack_generate_build() {
  local dockerfile="$1"
  local lang="$2"
  local build_dir="$3"

  case "$lang" in
    nodejs|node)
      # Only run build step - dependencies already installed by buildpack_generate_deps
      # Prefer heroku-postbuild over build (matches Heroku behavior)
      cat >> "$dockerfile" <<'EOF'
# Build: Node.js assets
RUN if [ -f package.json ]; then \
      if grep -q '"heroku-postbuild"' package.json 2>/dev/null; then npm run heroku-postbuild; \
      elif grep -q '"build:prod"' package.json 2>/dev/null; then npm run build:prod; \
      elif grep -q '"build:production"' package.json 2>/dev/null; then npm run build:production; \
      elif grep -q '"build"' package.json 2>/dev/null; then npm run build; fi \
    fi
EOF
      ;;
    python)
      local pip_cache_id=$(get_cache_id pip)
      if [ -f "$build_dir/requirements.txt" ]; then
        if [ "$USE_CACHE_MOUNTS" = "true" ]; then
          cat >> "$dockerfile" <<EOF
# Build: Python dependencies
RUN --mount=type=cache,id=${pip_cache_id},target=/root/.cache/pip,sharing=shared \\
    pip install -r requirements.txt
EOF
        else
          cat >> "$dockerfile" <<'EOF'
# Build: Python dependencies
RUN pip install -r requirements.txt
EOF
        fi
      elif [ -f "$build_dir/pyproject.toml" ]; then
        if [ "$USE_CACHE_MOUNTS" = "true" ]; then
          cat >> "$dockerfile" <<EOF
# Build: Python dependencies (pyproject.toml)
RUN --mount=type=cache,id=${pip_cache_id},target=/root/.cache/pip,sharing=shared \\
    pip install .
EOF
        else
          cat >> "$dockerfile" <<'EOF'
# Build: Python dependencies (pyproject.toml)
RUN pip install .
EOF
        fi
      fi
      ;;
    ruby)
      local bundle_cache_id=$(get_cache_id bundle)
      if [ -f "$build_dir/Gemfile" ]; then
        if [ "$USE_CACHE_MOUNTS" = "true" ]; then
          cat >> "$dockerfile" <<EOF
# Build: Ruby dependencies
RUN --mount=type=cache,id=${bundle_cache_id},target=/root/.bundle/cache,sharing=shared \\
    bundle config set --local path 'vendor/bundle' && \\
    bundle install --jobs=4 --retry=3
EOF
        else
          cat >> "$dockerfile" <<'EOF'
# Build: Ruby dependencies
RUN bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3
EOF
        fi
      fi
      ;;
    go|golang)
      local go_cache_id=$(get_cache_id go)
      if [ -f "$build_dir/go.mod" ]; then
        if [ "$USE_CACHE_MOUNTS" = "true" ]; then
          cat >> "$dockerfile" <<EOF
# Build: Go dependencies and binary
RUN --mount=type=cache,id=${go_cache_id},target=/go/pkg/mod,sharing=shared \\
    go mod download
RUN --mount=type=cache,id=${go_cache_id},target=/go/pkg/mod,sharing=shared \\
    --mount=type=cache,target=/root/.cache/go-build,sharing=shared \\
    CGO_ENABLED=0 go build -o ./bin/app ./...
EOF
        else
          cat >> "$dockerfile" <<'EOF'
# Build: Go dependencies and binary
RUN go mod download
RUN CGO_ENABLED=0 go build -o ./bin/app ./...
EOF
        fi
      fi
      ;;
  esac
}

# Generate runtime COPY commands for final image
# Copies runtimes from builder stage to runtime stage
# Args: dockerfile, additional_langs array, is_dhi
buildpack_generate_runtime_copies() {
  local dockerfile="$1"
  local is_dhi="$2"
  shift 2
  local additional_langs=("$@")

  if [ ${#additional_langs[@]} -eq 0 ]; then
    return
  fi

  # For DHI, we can't add runtimes to distroless
  if [ "$is_dhi" = "true" ]; then
    return
  fi

  for lang in "${additional_langs[@]}"; do
    case "$lang" in
      nodejs|node)
        cat >> "$dockerfile" <<'EOF'
# Runtime: Node.js (for scripts that need node)
COPY --from=builder /usr/local/bin/node /usr/local/bin/
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
EOF
        ;;
      python)
        cat >> "$dockerfile" <<'EOF'
# Runtime: Python
COPY --from=builder /usr/local/bin/python* /usr/local/bin/
COPY --from=builder /usr/local/lib/python* /usr/local/lib/
COPY --from=builder /usr/local/lib/libpython* /usr/local/lib/
EOF
        ;;
      ruby)
        cat >> "$dockerfile" <<'EOF'
# Runtime: Ruby
COPY --from=builder /usr/local/bin/ruby /usr/local/bin/
COPY --from=builder /usr/local/lib/ruby /usr/local/lib/ruby
COPY --from=builder /usr/local/lib/libruby* /usr/local/lib/
EOF
        ;;
      go|golang)
        # Go compiles to static binary, no runtime needed
        ;;
    esac
  done
}
