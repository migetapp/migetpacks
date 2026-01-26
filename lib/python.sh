#!/bin/bash
# Python build support for migetpacks

# Get Docker images for Python builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
python_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/python:${version}-dev"
    RUNTIME_IMAGE="dhi.io/python:${version}"
  else
    BUILD_IMAGE="python:${version}"
    RUNTIME_IMAGE="python:${version}-slim"
  fi
}

# Detect which runtime libraries are needed based on requirements
# Sets: PYTHON_APT_PACKAGES
python_detect_dependencies() {
  local build_dir="$1"

  local needs_libpq=false
  local needs_mysql=false
  local needs_sqlite=false
  local needs_lxml=false

  # Check requirements.txt
  if [ -f "$build_dir/requirements.txt" ]; then
    grep -qiE "psycopg|asyncpg|aiopg" "$build_dir/requirements.txt" && needs_libpq=true
    grep -qiE "mysqlclient|pymysql|aiomysql" "$build_dir/requirements.txt" && needs_mysql=true
    grep -qiE "aiosqlite" "$build_dir/requirements.txt" && needs_sqlite=true
    grep -qiE "^lxml" "$build_dir/requirements.txt" && needs_lxml=true
  fi

  # Check pyproject.toml (for uv/poetry projects)
  if [ -f "$build_dir/pyproject.toml" ]; then
    grep -qiE "psycopg|asyncpg|aiopg" "$build_dir/pyproject.toml" && needs_libpq=true
    grep -qiE "mysqlclient|pymysql|aiomysql" "$build_dir/pyproject.toml" && needs_mysql=true
    grep -qiE "aiosqlite" "$build_dir/pyproject.toml" && needs_sqlite=true
    grep -qiE "\"lxml\"" "$build_dir/pyproject.toml" && needs_lxml=true
  fi

  # Check uv.lock for dependencies
  if [ -f "$build_dir/uv.lock" ]; then
    grep -qiE "name = \"psycopg|name = \"asyncpg|name = \"aiopg" "$build_dir/uv.lock" && needs_libpq=true
    grep -qiE "name = \"mysqlclient|name = \"pymysql|name = \"aiomysql" "$build_dir/uv.lock" && needs_mysql=true
    grep -qiE "name = \"aiosqlite" "$build_dir/uv.lock" && needs_sqlite=true
    grep -qiE "name = \"lxml" "$build_dir/uv.lock" && needs_lxml=true
  fi

  # Build apt packages list
  PYTHON_APT_PACKAGES=""
  [ "$needs_libpq" = true ] && PYTHON_APT_PACKAGES="$PYTHON_APT_PACKAGES libpq5"
  [ "$needs_mysql" = true ] && PYTHON_APT_PACKAGES="$PYTHON_APT_PACKAGES libmariadb3"
  [ "$needs_sqlite" = true ] && PYTHON_APT_PACKAGES="$PYTHON_APT_PACKAGES libsqlite3-0"
  [ "$needs_lxml" = true ] && PYTHON_APT_PACKAGES="$PYTHON_APT_PACKAGES libxml2 libxslt1.1"
}

# Check if this is a uv project
python_is_uv_project() {
  local build_dir="$1"
  [ -f "$build_dir/uv.lock" ]
}

# Generate builder stage for Python
# Args: dockerfile_path, build_dir, build_command
python_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Cache mount prefix (only when BUILD_CACHE_DIR is set for persistent storage)
  local mount_prefix=""
  if [ "$USE_CACHE_MOUNTS" = "true" ]; then
    mount_prefix="--mount=type=cache,target=/root/.cache/pip,sharing=shared --mount=type=cache,target=/root/.cache/uv,sharing=shared "
  fi

  # Python-optimized layer caching: copy requirements first, pip install, then copy rest
  cat >> "$dockerfile" <<'EOF'
# Copy dependency files first for layer caching (pip install cached if requirements unchanged)
COPY requirements.txt* pyproject.toml* poetry.lock* Pipfile* uv.lock* ./
ENV PYTHONUNBUFFERED=1
ENV LANG=en_US.UTF-8
EOF

  if python_is_uv_project "$build_dir"; then
    # uv project: use native uv for package management
    cat >> "$dockerfile" <<EOF
RUN ${mount_prefix}pip install uv \\
    && uv venv /app/.venv \\
    && UV_PROJECT_ENVIRONMENT=/app/.venv uv sync --locked --no-dev

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN ${build_command} \\
    && find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \\
       rm -rf .git .github .gitignore test tests pytest.ini .pytest_cache .coverage htmlcov 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN if [ -f manage.py ]; then /app/.venv/bin/python manage.py collectstatic --noinput 2>/dev/null || true; fi \
    && find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
       rm -rf .git .github .gitignore test tests pytest.ini .pytest_cache .coverage htmlcov 2>/dev/null; true
EOF
    fi
    echo 'ENV PATH="/app/.venv/bin:$PATH"' >> "$dockerfile"
  else
    # Non-uv Python: use pip/pipenv/poetry with venv
    # Split into two layers for better caching:
    # Layer 1: venv creation + pip upgrade (rarely changes - only on Python version change)
    # Layer 2: pip install (cached if requirements unchanged)
    cat >> "$dockerfile" <<'EOF'
# Create virtualenv (cached unless Python version changes)
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip
EOF
    # pip install layer (cached if requirements unchanged)
    cat >> "$dockerfile" <<EOF
RUN ${mount_prefix}. /opt/venv/bin/activate \\
    && if [ -f requirements.txt ]; then pip install -r requirements.txt; \\
       elif [ -f Pipfile.lock ]; then pip install pipenv && pipenv install --deploy; \\
       elif [ -f Pipfile ]; then pip install pipenv && pipenv install; \\
       elif [ -f poetry.lock ]; then pip install poetry && poetry install --no-interaction --no-ansi; \\
       elif [ -f pyproject.toml ]; then pip install .; fi

# Copy rest of source code (this layer changes on every code change)
COPY . .
EOF
    # Build/collectstatic layer with cleanup
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF
RUN . /opt/venv/bin/activate && ${build_command} \\
    && find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \\
       rm -rf .git .github .gitignore test tests pytest.ini .pytest_cache .coverage htmlcov 2>/dev/null; true
EOF
    else
      cat >> "$dockerfile" <<'EOF'
RUN . /opt/venv/bin/activate && if [ -f manage.py ]; then python manage.py collectstatic --noinput 2>/dev/null || true; fi \
    && find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
       rm -rf .git .github .gitignore test tests pytest.ini .pytest_cache .coverage htmlcov 2>/dev/null; true
EOF
    fi
    echo 'ENV PATH="/opt/venv/bin:$PATH"' >> "$dockerfile"
  fi
}

# Generate runtime stage base for Python (apt-get install, user creation)
# Args: dockerfile_path, runtime_image, build_dir
python_generate_runtime_base() {
  local dockerfile="$1"
  local runtime_image="$2"
  local build_dir="$3"

  # Detect dependencies
  python_detect_dependencies "$build_dir"

  cat >> "$dockerfile" <<DOCKERFILE_FOOTER

# Runtime stage
FROM ${runtime_image}

# Create non-root user with home directory
RUN getent group 1000 >/dev/null 2>&1 || groupadd -g 1000 miget; \\
    getent passwd 1000 >/dev/null 2>&1 || useradd -u 1000 -g 1000 -m miget; \\
    mkdir -p /home/miget && chown 1000:1000 /home/miget
DOCKERFILE_FOOTER

  # Install runtime dependencies BEFORE copying app (for layer caching)
  if [ -n "$PYTHON_APT_PACKAGES" ]; then
    cat >> "$dockerfile" <<EOF

# Install runtime dependencies BEFORE copying app (for layer caching)
RUN apt-get update && apt-get install -y --no-install-recommends ${PYTHON_APT_PACKAGES} \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
  fi

  cat >> "$dockerfile" <<'DOCKERFILE_FOOTER'

WORKDIR /app

# Copy application from builder
COPY --from=builder --chown=1000:1000 /build /app
DOCKERFILE_FOOTER
}

# Generate runtime stage environment for Python
# Args: dockerfile_path, is_dhi_image, dhi_user, build_dir
python_generate_runtime() {
  local dockerfile="$1"
  local is_dhi_image="$2"
  local dhi_user="$3"
  local build_dir="$4"

  local is_uv=false
  python_is_uv_project "$build_dir" && is_uv=true

  if [ "$is_dhi_image" = true ]; then
    if [ "$is_uv" = true ]; then
      cat >> "$dockerfile" <<EOF

# Copy uv venv from builder
COPY --from=builder --chown=${dhi_user}:${dhi_user} /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:\$PATH"

# Python production environment
ENV PYTHONUNBUFFERED=1
ENV LANG=en_US.UTF-8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app
ENV FORWARDED_ALLOW_IPS=*
EOF
    else
      cat >> "$dockerfile" <<EOF

# Copy virtualenv from builder
COPY --from=builder --chown=${dhi_user}:${dhi_user} /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:\$PATH"

# Python production environment
ENV PYTHONUNBUFFERED=1
ENV LANG=en_US.UTF-8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app
ENV FORWARDED_ALLOW_IPS=*
EOF
    fi
  else
    if [ "$is_uv" = true ]; then
      cat >> "$dockerfile" <<'EOF'

# Copy uv venv from builder
COPY --from=builder --chown=1000:1000 /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Python production environment
ENV PYTHONUNBUFFERED=1
ENV LANG=en_US.UTF-8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app
ENV FORWARDED_ALLOW_IPS=*
EOF
    else
      cat >> "$dockerfile" <<'EOF'

# Copy virtualenv from builder
COPY --from=builder --chown=1000:1000 /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Python production environment
ENV PYTHONUNBUFFERED=1
ENV LANG=en_US.UTF-8
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app
ENV FORWARDED_ALLOW_IPS=*
EOF
    fi
  fi
}
