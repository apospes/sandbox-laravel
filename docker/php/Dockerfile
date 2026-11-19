# =============================================================================
# Laravel application image: PHP-FPM + Composer + Node.js LTS + Xdebug
# Build args are fed from docker-compose.yml (which reads the project .env).
# =============================================================================
ARG PHP_VERSION=8.3
# Node.js major version (22 = current LTS). Change in .env (NODE_MAJOR).
ARG NODE_MAJOR=22

# Node.js is copied from the official Docker Hub image (same Debian bookworm
# base as the PHP image). This avoids downloading from third-party HTTPS
# servers during the build, which fails on networks that intercept TLS.
FROM node:${NODE_MAJOR}-bookworm-slim AS node_source

FROM php:${PHP_VERSION}-fpm-bookworm

# Match the container user to your host user so files in ./src stay editable
# on the host. setup.sh writes the right values into .env.
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG APP_USER=app

ENV COMPOSER_HOME=/home/${APP_USER}/.composer \
    COMPOSER_MEMORY_LIMIT=-1 \
    COMPOSER_ALLOW_SUPERUSER=0

# --- System packages + PHP extensions ---------------------------------------
# Built with the official image helpers (docker-php-ext-*) and PECL, so only
# Docker Hub and the Debian repositories are needed (no ghcr.io).
# Already compiled into the official image: mbstring, xml/dom, curl, openssl,
# fileinfo, tokenizer, ctype, sqlite3, pdo_sqlite.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS \
        bash git unzip zip curl ca-certificates gnupg sqlite3 default-mysql-client \
        libpng-dev libjpeg-dev libfreetype6-dev libwebp-dev \
        libzip-dev libicu-dev libonig-dev libxml2-dev libsqlite3-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql gd zip bcmath intl exif pcntl opcache \
 && pecl install xdebug \
 && docker-php-ext-enable xdebug \
 && rm -rf /var/lib/apt/lists/* /tmp/pear \
 && for ext in pdo_mysql pdo_sqlite sqlite3 gd mbstring xml curl zip bcmath intl fileinfo openssl xdebug; do \
        php -m | grep -qix "$ext" || { echo "ERROR: PHP extension '$ext' is missing" >&2; exit 1; }; \
    done

# --- Composer (latest stable 2.x) ------------------------------------------
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# --- Node.js LTS + npm (copied from the official node image) ----------------
COPY --from=node_source /usr/local/bin/node /usr/local/bin/node
COPY --from=node_source /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && node --version && npm --version

# --- Non-root application user ---------------------------------------------
# -o allows a non-unique id, so a host UID/GID that already exists in the image
# does not break the build.
RUN groupadd -o -g "${HOST_GID}" "${APP_USER}" \
 && useradd  -o -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash "${APP_USER}" \
 && mkdir -p /var/www/html /home/${APP_USER}/.composer/cache /home/${APP_USER}/.npm \
 && chown -R "${HOST_UID}:${HOST_GID}" /var/www/html /home/${APP_USER}

# --- PHP / FPM configuration ------------------------------------------------
# Run the whole FPM process tree as the non-root user: disable the pool's
# user/group directives (they only work when FPM starts as root).
RUN sed -i -E 's/^(user|group) = /;\1 = /' /usr/local/etc/php-fpm.d/www.conf

COPY php.ini  ${PHP_INI_DIR}/conf.d/99-app.ini
COPY conf.d/  ${PHP_INI_DIR}/conf.d/

WORKDIR /var/www/html
USER ${APP_USER}

EXPOSE 9000
CMD ["php-fpm"]
