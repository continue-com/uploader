# Uguu development environment
#
# This image builds the web assets with Bun and sets up Nginx + PHP 8.3 (FPM)
# with required PHP extensions (fileinfo, PDO/SQLite, APCu). It uses the
# default SQLite configuration from src/config.json and stores data under:
#   - /var/www/files  (uploaded files)
#   - /var/www/db     (SQLite database)
#
# You can override config.json as needed; by default DB_MODE=sqlite.

FROM alpine:3.20

ENV PHP_V=83 \
    APP_DIR=/app \
    DIST_DIR=/app/dist \
    FILES_DIR=/var/www/files \
    DB_DIR=/var/www/db \
    NGINX_USER=nginx

# Base packages: nginx, php-fpm + needed extensions, composer, build tools
RUN apk add --no-cache \
    bash curl git ca-certificates unzip tar make findutils coreutils \
    pngquant jq sqlite \
    nginx \
    php${PHP_V} php${PHP_V}-fpm php${PHP_V}-opcache php${PHP_V}-session \
    php${PHP_V}-ctype php${PHP_V}-fileinfo php${PHP_V}-curl php${PHP_V}-mbstring \
    php${PHP_V}-pdo php${PHP_V}-pdo_sqlite php${PHP_V}-sqlite3 \
    php${PHP_V}-zip php${PHP_V}-phar php${PHP_V}-openssl \
    php${PHP_V}-dom php${PHP_V}-xml php${PHP_V}-tokenizer \
    php${PHP_V}-pecl-apcu \
    composer \
  && update-ca-certificates

# Provide generic php/php-fpm names expected by tooling/Makefile
RUN ln -sf /usr/bin/php${PHP_V} /usr/bin/php \
 && ln -sf /usr/sbin/php-fpm${PHP_V} /usr/sbin/php-fpm

# Install Bun (for building assets). Bun provides Linux/musl builds suitable for Alpine.
RUN curl -fsSL https://bun.sh/install | bash \
  && ln -s /root/.bun/bin/bun /usr/local/bin/bun

WORKDIR ${APP_DIR}

# Copy project files
COPY . ${APP_DIR}

# Build web assets and install into dist/ (dev install keeps dev tooling)
# Note: Use --ignore-scripts to skip native postinstall scripts (e.g. gifsicle)
# that fail on Alpine/musl. We don't rely on those binaries during the build.
RUN bun install --ignore-scripts \
  && make development \
  && make install-dev \
  && rm -rf ${APP_DIR}/build

# Prepare runtime directories for uploads and database
RUN mkdir -p ${FILES_DIR} ${DB_DIR} \
  && chown -R ${NGINX_USER}:${NGINX_USER} ${FILES_DIR} ${DB_DIR} ${DIST_DIR}

# Runtime dirs for nginx
RUN mkdir -p /run/nginx /var/cache/nginx \
  && chown -R ${NGINX_USER}:${NGINX_USER} /run/nginx /var/cache/nginx

# Nginx configuration
COPY docker/nginx.conf /etc/nginx/nginx.conf

# PHP-FPM configuration tweaks: listen on 127.0.0.1:9000 and run as nginx user
RUN sed -i 's|^;*listen = .*|listen = 127.0.0.1:9000|' /etc/php${PHP_V}/php-fpm.d/www.conf \
 && sed -i "s|^user = .*|user = ${NGINX_USER}|" /etc/php${PHP_V}/php-fpm.d/www.conf \
 && sed -i "s|^group = .*|group = ${NGINX_USER}|" /etc/php${PHP_V}/php-fpm.d/www.conf \
 && sed -i 's|^;*clear_env = .*|clear_env = no|' /etc/php${PHP_V}/php-fpm.d/www.conf \
 && sed -i 's|^;*catch_workers_output = .*|catch_workers_output = yes|' /etc/php${PHP_V}/php-fpm.d/www.conf

# Increase PHP upload limits for development
RUN printf "upload_max_filesize=500M\npost_max_size=500M\nmemory_limit=512M\nmax_file_uploads=100\n" \
    > /etc/php${PHP_V}/conf.d/99-uguu.ini

# Entrypoint to run php-fpm and nginx together
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose HTTP port
EXPOSE 8080

# Healthcheck: ensure Nginx answers on port 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=5 CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
