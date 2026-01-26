#!/bin/bash
# PHP build support for migetpacks

# Get Docker images for PHP builds
# Sets: BUILD_IMAGE, RUNTIME_IMAGE
php_get_images() {
  local version="$1"
  local use_dhi="$2"

  if [ "$use_dhi" = "true" ]; then
    BUILD_IMAGE="dhi.io/php:${version}-dev"
    RUNTIME_IMAGE="dhi.io/php:${version}"
  else
    # FrankenPHP: modern PHP app server (Go + Caddy based)
    local php_major_minor=$(echo "$version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
    case "$php_major_minor" in
      8.2|8.3|8.4)
        if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
          BUILD_IMAGE="dunglas/frankenphp:builder-php${version}"
          RUNTIME_IMAGE="dunglas/frankenphp:php${version}"
        else
          BUILD_IMAGE="dunglas/frankenphp:builder-php${php_major_minor}"
          RUNTIME_IMAGE="dunglas/frankenphp:php${php_major_minor}"
        fi
        ;;
      *)
        # FrankenPHP minimum is 8.2, fallback for 8.1 and older
        warning "PHP ${php_major_minor} not supported by FrankenPHP, using PHP 8.2"
        BUILD_IMAGE="dunglas/frankenphp:builder-php8.2"
        RUNTIME_IMAGE="dunglas/frankenphp:php8.2"
        ;;
    esac
  fi
}

# Detect PHP extensions from composer.json
php_detect_extensions() {
  local build_dir="$1"

  if [ -f "$build_dir/composer.json" ]; then
    jq -r '.require // {} | keys[] | select(startswith("ext-")) | sub("ext-"; "")' "$build_dir/composer.json" 2>/dev/null | tr '\n' ' ' | xargs
  fi
}

# Detect web root directory
php_detect_webroot() {
  local build_dir="$1"

  for dir in web public html www; do
    if [ -d "$build_dir/$dir" ]; then
      echo "$dir"
      return
    fi
  done
  echo "."
}

# Generate builder stage for PHP
# Args: dockerfile_path, build_dir, build_command
php_generate_builder() {
  local dockerfile="$1"
  local build_dir="$2"
  local build_command="$3"

  # Get per-app cache ID for BuildKit PVC cache
  local composer_id=$(get_cache_id composer)

  # Detect PHP extensions
  local php_extensions=$(php_detect_extensions "$build_dir")

  # Check if this is a DHI image
  local is_dhi_image="false"
  if [[ "$BUILD_IMAGE" == dhi.io/* ]]; then
    is_dhi_image="true"
  fi

  # Install PHP extensions if needed
  if [ -n "$php_extensions" ]; then
    if [ "$is_dhi_image" = "true" ]; then
      cat >> "$dockerfile" <<EOF
# Install PHP extensions: $php_extensions
RUN for ext in $php_extensions; do \\
      if ! php -m | grep -qi "\$ext"; then \\
        echo "Installing extension: \$ext" && \\
        pecl install "\$ext" 2>/dev/null || echo "Extension \$ext may be bundled or unavailable"; \\
        echo "extension=\$ext.so" >> \$PHP_INI_DIR/conf.d/\$ext.ini 2>/dev/null || true; \\
      fi; \\
    done
EOF
    else
      cat >> "$dockerfile" <<EOF
# Install PHP extensions: $php_extensions
RUN apt-get update && apt-get install -y --no-install-recommends \\
      libpng-dev libjpeg-dev libfreetype6-dev libzip-dev libicu-dev libpq-dev libonig-dev \\
    && docker-php-ext-configure gd --with-freetype --with-jpeg 2>/dev/null || true \\
    && for ext in $php_extensions; do \\
         docker-php-ext-install "\$ext" 2>/dev/null || echo "Extension \$ext may need manual installation"; \\
       done \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
    fi
  fi

  # Install unzip for Composer zip downloads (FrankenPHP builder doesn't include it)
  if [ "$is_dhi_image" != "true" ]; then
    cat >> "$dockerfile" <<'EOF'

# Install unzip for faster Composer downloads (zip instead of git clone)
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
EOF
  fi

  # Check if composer.json exists
  if [ ! -f "$build_dir/composer.json" ]; then
    # No composer, just copy everything
    cat >> "$dockerfile" <<'EOF'

# No composer.json, copy source files
COPY . .
EOF
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

RUN ${build_command}
EOF
    fi
    return
  fi

  # Copy composer files first for layer caching
  cat >> "$dockerfile" <<'EOF'

# Copy composer files for layer caching (dependencies cached if unchanged)
COPY composer.json composer.lock* ./
EOF

  if [ "$is_dhi_image" = "true" ]; then
    # DHI images: install composer locally
    if [ "$USE_CACHE_MOUNTS" = "true" ]; then
      cat >> "$dockerfile" <<EOF

# Install composer and dependencies (cached if composer.json/lock unchanged)
RUN --mount=type=cache,id=${composer_id},target=/root/.composer,sharing=shared \\
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \\
    && php composer-setup.php \\
    && php -r "unlink('composer-setup.php');" \\
    && php composer.phar install --no-dev --optimize-autoloader --ignore-platform-reqs --no-scripts

# Copy rest of source code
COPY . .
EOF
    else
      cat >> "$dockerfile" <<'EOF'

# Install composer and dependencies
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
    && php composer-setup.php \
    && php -r "unlink('composer-setup.php');" \
    && php composer.phar install --no-dev --optimize-autoloader --ignore-platform-reqs --no-scripts

# Copy rest of source code
COPY . .
EOF
    fi

    # Run post-install scripts and build command
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Run composer scripts and build command
RUN php composer.phar run-script post-install-cmd --no-interaction 2>/dev/null || true \\
    && ${build_command} \\
    && rm -f composer.phar
EOF
    else
      cat >> "$dockerfile" <<'EOF'

# Run composer scripts and cleanup
RUN php composer.phar run-script post-install-cmd --no-interaction 2>/dev/null || true \
    && rm -f composer.phar
EOF
    fi
  else
    # Non-DHI (FrankenPHP): use curl to install composer
    if [ "$USE_CACHE_MOUNTS" = "true" ]; then
      cat >> "$dockerfile" <<EOF

# Install composer and dependencies (cached if composer.json/lock unchanged)
RUN --mount=type=cache,id=${composer_id},target=/root/.composer,sharing=shared \\
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \\
    && composer install --no-dev --optimize-autoloader --no-scripts

# Copy rest of source code
COPY . .
EOF
    else
      cat >> "$dockerfile" <<'EOF'

# Install composer and dependencies
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && composer install --no-dev --optimize-autoloader --no-scripts

# Copy rest of source code
COPY . .
EOF
    fi

    # Run post-install scripts and build command
    if [ -n "$build_command" ]; then
      cat >> "$dockerfile" <<EOF

# Run composer scripts and build command
RUN composer run-script post-install-cmd --no-interaction 2>/dev/null || true \\
    && ${build_command}
EOF
    else
      cat >> "$dockerfile" <<'EOF'

# Run composer scripts
RUN composer run-script post-install-cmd --no-interaction 2>/dev/null || true
EOF
    fi
  fi
}

# Generate runtime stage base for PHP
# Args: dockerfile_path, runtime_image
php_generate_runtime_base() {
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

# Generate runtime stage environment for PHP
# Args: dockerfile_path, build_dir
php_generate_runtime() {
  local dockerfile="$1"
  local build_dir="$2"

  # Detect web root directory
  local php_webroot=$(php_detect_webroot "$build_dir")

  cat >> "$dockerfile" <<EOF

# PHP production ini settings
ENV PHP_INI_MEMORY_LIMIT=256M
ENV PHP_INI_MAX_EXECUTION_TIME=30
ENV PHP_INI_MAX_INPUT_TIME=60
ENV PHP_INI_POST_MAX_SIZE=64M
ENV PHP_INI_UPLOAD_MAX_FILESIZE=32M
ENV PHP_INI_MAX_FILE_UPLOADS=20
ENV PHP_INI_DISPLAY_ERRORS=Off
ENV PHP_INI_LOG_ERRORS=On
ENV PHP_INI_ERROR_REPORTING=E_ALL
ENV PHP_INI_EXPOSE_PHP=Off
ENV PHP_INI_DATE_TIMEZONE=UTC
ENV PHP_INI_SESSION_USE_STRICT_MODE=1
ENV PHP_INI_SESSION_USE_COOKIES=1
ENV PHP_INI_SESSION_USE_ONLY_COOKIES=1
ENV PHP_INI_SESSION_COOKIE_HTTPONLY=1
ENV PHP_INI_SESSION_COOKIE_SECURE=1
ENV PHP_INI_SESSION_COOKIE_SAMESITE=Strict
ENV PHP_INI_OPCACHE_ENABLE=1
ENV PHP_INI_OPCACHE_MEMORY_CONSUMPTION=128
ENV PHP_INI_OPCACHE_VALIDATE_TIMESTAMPS=0
ENV PHP_INI_REALPATH_CACHE_SIZE=4096K
ENV PHP_INI_REALPATH_CACHE_TTL=600

# FrankenPHP environment
ENV CADDY_ADMIN=off
ENV PHP_WEBROOT=${php_webroot}

# Configure PHP ini and Caddy data directory
RUN mkdir -p /app/${php_webroot} /data/caddy \\
    && chown -R 1000:1000 /data/caddy \\
    && echo 'memory_limit = \${PHP_INI_MEMORY_LIMIT}' > /usr/local/lib/php.ini \\
    && echo 'max_execution_time = \${PHP_INI_MAX_EXECUTION_TIME}' >> /usr/local/lib/php.ini \\
    && echo 'max_input_time = \${PHP_INI_MAX_INPUT_TIME}' >> /usr/local/lib/php.ini \\
    && echo 'post_max_size = \${PHP_INI_POST_MAX_SIZE}' >> /usr/local/lib/php.ini \\
    && echo 'upload_max_filesize = \${PHP_INI_UPLOAD_MAX_FILESIZE}' >> /usr/local/lib/php.ini \\
    && echo 'max_file_uploads = \${PHP_INI_MAX_FILE_UPLOADS}' >> /usr/local/lib/php.ini \\
    && echo 'display_errors = \${PHP_INI_DISPLAY_ERRORS}' >> /usr/local/lib/php.ini \\
    && echo 'log_errors = \${PHP_INI_LOG_ERRORS}' >> /usr/local/lib/php.ini \\
    && echo 'error_reporting = \${PHP_INI_ERROR_REPORTING}' >> /usr/local/lib/php.ini \\
    && echo 'expose_php = \${PHP_INI_EXPOSE_PHP}' >> /usr/local/lib/php.ini \\
    && echo 'date.timezone = \${PHP_INI_DATE_TIMEZONE}' >> /usr/local/lib/php.ini \\
    && echo 'session.use_strict_mode = \${PHP_INI_SESSION_USE_STRICT_MODE}' >> /usr/local/lib/php.ini \\
    && echo 'session.use_cookies = \${PHP_INI_SESSION_USE_COOKIES}' >> /usr/local/lib/php.ini \\
    && echo 'session.use_only_cookies = \${PHP_INI_SESSION_USE_ONLY_COOKIES}' >> /usr/local/lib/php.ini \\
    && echo 'session.cookie_httponly = \${PHP_INI_SESSION_COOKIE_HTTPONLY}' >> /usr/local/lib/php.ini \\
    && echo 'session.cookie_secure = \${PHP_INI_SESSION_COOKIE_SECURE}' >> /usr/local/lib/php.ini \\
    && echo 'session.cookie_samesite = \${PHP_INI_SESSION_COOKIE_SAMESITE}' >> /usr/local/lib/php.ini \\
    && echo 'opcache.enable = \${PHP_INI_OPCACHE_ENABLE}' >> /usr/local/lib/php.ini \\
    && echo 'opcache.memory_consumption = \${PHP_INI_OPCACHE_MEMORY_CONSUMPTION}' >> /usr/local/lib/php.ini \\
    && echo 'opcache.validate_timestamps = \${PHP_INI_OPCACHE_VALIDATE_TIMESTAMPS}' >> /usr/local/lib/php.ini \\
    && echo 'realpath_cache_size = \${PHP_INI_REALPATH_CACHE_SIZE}' >> /usr/local/lib/php.ini \\
    && echo 'realpath_cache_ttl = \${PHP_INI_REALPATH_CACHE_TTL}' >> /usr/local/lib/php.ini
EOF
}
