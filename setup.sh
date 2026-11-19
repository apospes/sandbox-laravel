#!/usr/bin/env bash
# =============================================================================
# setup.sh - bootstrap (or re-bootstrap) the Laravel Docker environment.
#
# Safe to re-run: it never deletes volumes, databases or application files,
# keeps your existing .env values, and only creates what is missing.
# Needs on the host: Docker + Docker Compose V2 (nothing else).
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---------- output helpers ---------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_OFF=''
fi
info() { printf '%s==>%s %s\n'   "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s ok%s %s\n'   "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%swarn%s %s\n'  "$C_YLW" "$C_OFF" "$*" >&2; }
err()  { printf '%serror%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }
trap 'err "Setup stopped at line $LINENO. Fix the problem above and re-run ./setup.sh (it is safe to re-run)."' ERR

dc()  { docker compose "$@"; }
app() { docker compose exec -T app "$@"; }

# ---------- .env helpers -----------------------------------------------------
# env_get FILE KEY            -> prints the value of an active KEY=value line
env_get() {
    { grep -E "^${2}=" "$1" 2>/dev/null || true; } | tail -n1 | cut -d= -f2-
}

# env_set FILE KEY VALUE [ALLOW_COMMENTED]
# Replaces the first KEY=... line (or "# KEY=..." when ALLOW_COMMENTED=1),
# otherwise appends KEY=VALUE. Uses awk so special characters are safe.
env_set() {
    local file=$1 key=$2 value=$3 commented=${4:-0} tmp prefix='^'
    if [ "$commented" = 1 ]; then prefix='^[# ]*'; fi
    tmp=$(mktemp)
    if grep -qE "${prefix}${key}=" "$file"; then
        K="$key" V="$value" P="$prefix" awk '
            BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; p = ENVIRON["P"]; done = 0 }
            { if (!done && match($0, p k "=")) { print k "=" v; done = 1 } else print }
        ' "$file" > "$tmp"
    else
        cp "$file" "$tmp"
        [ -n "$(tail -c1 "$tmp")" ] && printf '\n' >> "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    cat "$tmp" > "$file"   # write in place: keeps inode, permissions and bind mounts intact
    rm -f "$tmp"
}

has_key() { grep -qE "^${2}=" "$1"; }

# 32 random alphanumeric characters (no shell/URL-hostile characters).
gen_secret() {
    ( set +o pipefail; head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 )
}

# Directory name -> valid Docker Compose project identifier.
slugify() {
    local s
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^[^a-z0-9]+//; s/[-_]+$//')
    s=${s:0:40}
    printf '%s' "${s:-laravel-app}"
}

# ---------- 1-2. prerequisites ----------------------------------------------
check_prerequisites() {
    info "Checking prerequisites"
    command -v docker >/dev/null 2>&1 \
        || die "Docker is not installed. Install it: https://docs.docker.com/engine/install/ubuntu/"
    docker info >/dev/null 2>&1 \
        || die "Cannot reach the Docker daemon. Is it running? Is your user in the 'docker' group?
       Fix: sudo usermod -aG docker \$USER   (then log out and back in)"
    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose V2 is missing. On Ubuntu: sudo apt-get install docker-compose-plugin"
    ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), $(docker compose version --short 2>/dev/null || echo 'compose')"
    if [ "$(id -u)" -eq 0 ]; then
        warn "Running as root: files in src/ would be owned by root. Run as a normal user in the docker group."
    fi
}

# ---------- 3-7. .env --------------------------------------------------------
ensure_env_file() {
    local dir_id project db_name key line
    [ -f .env.example ] || die ".env.example not found - is this the template directory?"

    if [ ! -f .env ]; then
        info "Creating .env from .env.example"
        cp .env.example .env
        chmod 600 .env
        dir_id=$(slugify "$(basename "$PWD")")
        env_set .env PROJECT_NAME "$dir_id"
        env_set .env DB_DATABASE  "$(printf '%s' "$dir_id" | tr '-' '_')"
        if [ "$(id -u)" -ne 0 ]; then
            env_set .env HOST_UID "$(id -u)"
            env_set .env HOST_GID "$(id -g)"
        fi
        ok "Project identifier: $dir_id"
    else
        info "Using existing .env (your settings are preserved)"
        # Add any keys introduced by a newer template without touching existing ones.
        while IFS= read -r line; do
            key=${line%%=*}
            has_key .env "$key" || { env_set .env "$key" "${line#*=}"; ok "Added missing setting $key"; }
        done < <(grep -E '^[A-Z][A-Z0-9_]*=' .env.example)
    fi

    # Secrets: only generated when empty, never overwritten.
    if [ -z "$(env_get .env DB_PASSWORD)" ]; then
        env_set .env DB_PASSWORD "$(gen_secret)"; ok "Generated DB_PASSWORD"
    fi
    if [ -z "$(env_get .env DB_ROOT_PASSWORD)" ]; then
        env_set .env DB_ROOT_PASSWORD "$(gen_secret)"; ok "Generated DB_ROOT_PASSWORD"
    fi

    # Validate values that would otherwise cause confusing Docker errors.
    project=$(env_get .env PROJECT_NAME)
    [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
        || die "PROJECT_NAME='$project' is invalid. Use lowercase letters, digits, '-' and '_' (start with a letter or digit)."
    db_name=$(env_get .env DB_DATABASE)
    [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_DATABASE='$db_name' may only contain letters, digits and '_'."
    [ "$(env_get .env DB_USERNAME)" != "root" ] || die "DB_USERNAME must not be 'root' (the root account is configured separately)."

    if [ "$(id -u)" -ne 0 ] && [ "$(env_get .env HOST_UID)" != "$(id -u)" ]; then
        warn "HOST_UID in .env ($(env_get .env HOST_UID)) differs from your user id ($(id -u)). Files in src/ may not be writable by you."
        warn "Set HOST_UID=$(id -u) and HOST_GID=$(id -g) in .env, then run: make build"
    fi
}

warn_if_ports_busy() {
    # Skip when this project's containers already run (they own the ports).
    [ -z "$(dc ps -q 2>/dev/null)" ] || return 0
    command -v ss >/dev/null 2>&1 || return 0
    local var port
    for var in APP_PORT MYSQL_PORT MAILPIT_WEB_PORT MAILPIT_SMTP_PORT VITE_PORT; do
        port=$(env_get .env "$var")
        [ -n "$port" ] || continue
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            warn "Host port $port ($var) is already in use. Change $var in .env if startup fails."
        fi
    done
}

# ---------- 8-10. Docker -----------------------------------------------------
wait_for_mysql() {
    local cid status i
    info "Waiting for MySQL to become healthy"
    cid=$(dc ps -q mysql)
    [ -n "$cid" ] || die "MySQL container was not created."
    for ((i = 0; i < 90; i++)); do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)
        if [ "$status" = healthy ]; then ok "MySQL is healthy"; return 0; fi
        sleep 2
    done
    err "MySQL did not become healthy within 3 minutes (last status: $status). Recent logs:"
    dc logs --tail=30 mysql >&2 || true
    err "If you changed DB passwords in .env after the first start, see README > Troubleshooting."
    return 1
}

# ---------- 11-13. Laravel ---------------------------------------------------
laravel_constraint() {
    local v
    v=$(env_get .env LARAVEL_VERSION)
    case "$v" in
        ''|latest)               printf '' ;;
        *[!0-9]*)                if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?(\.x)?$ ]]; then printf '^%s' "${v%.x}"; else printf '%s' "$v"; fi ;;
        *)                       printf '^%s.0' "$v" ;;
    esac
}

src_is_empty() {
    [ -z "$(find src -mindepth 1 -maxdepth 1 ! -name .gitkeep -print -quit 2>/dev/null)" ]
}

install_fresh_laravel() {
    local constraint
    constraint=$(laravel_constraint)
    info "src/ has no Laravel application - creating a fresh project (laravel/laravel ${constraint:-latest})"
    src_is_empty || die "src/ is not empty but contains no 'artisan' file. Move your files away or put a complete Laravel app in src/."
    app rm -rf /tmp/laravel-skeleton
    if [ -n "$constraint" ]; then
        app composer create-project --no-interaction --prefer-dist laravel/laravel /tmp/laravel-skeleton "$constraint"
    else
        app composer create-project --no-interaction --prefer-dist laravel/laravel /tmp/laravel-skeleton
    fi
    # -n: never overwrite anything that already exists in src/.
    app cp -an /tmp/laravel-skeleton/. /var/www/html/
    app rm -rf /tmp/laravel-skeleton
    FRESH_INSTALL=1
    ok "Laravel installed in src/"
}

configure_laravel_env() {
    local f=src/.env marker='# laravel-docker-template: configured' app_port
    if [ ! -f "$f" ]; then
        if [ -f src/.env.example ]; then cp src/.env.example "$f"; else : > "$f"; warn "No src/.env.example found; created an empty src/.env"; fi
        LARAVEL_ENV_CREATED=1
    fi
    if grep -qF "$marker" "$f"; then
        ok "src/.env already configured for Docker (left untouched)"
        return 0
    fi
    if [ "${LARAVEL_ENV_CREATED:-0}" != 1 ]; then
        cp -p "$f" "${f%.env}.env.pre-docker-template"
        warn "Existing src/.env backed up to src/.env.pre-docker-template before adding Docker settings"
    fi
    info "Configuring src/.env (MySQL + Mailpit via Docker service names)"
    app_port=$(env_get .env APP_PORT)
    env_set "$f" APP_URL         "http://localhost:${app_port:-8080}" 1
    env_set "$f" DB_CONNECTION   "$(env_get .env DB_CONNECTION)"      1
    env_set "$f" DB_HOST         "$(env_get .env DB_HOST)"            1
    env_set "$f" DB_PORT         "$(env_get .env DB_PORT)"            1
    env_set "$f" DB_DATABASE     "$(env_get .env DB_DATABASE)"        1
    env_set "$f" DB_USERNAME     "$(env_get .env DB_USERNAME)"        1
    env_set "$f" DB_PASSWORD     "$(env_get .env DB_PASSWORD)"        1
    env_set "$f" MAIL_MAILER     "$(env_get .env MAIL_MAILER)"        1
    env_set "$f" MAIL_HOST       "$(env_get .env MAIL_HOST)"          1
    env_set "$f" MAIL_PORT       "$(env_get .env MAIL_PORT)"          1
    env_set "$f" MAIL_USERNAME   "null"                               1
    env_set "$f" MAIL_PASSWORD   "null"                               1
    env_set "$f" MAIL_ENCRYPTION "null"                               1
    printf '%s\n' "$marker" >> "$f"
    FRESH_ENV_CONFIGURED=1
}

fix_permissions() {
    info "Setting Laravel storage / cache / SQLite permissions"
    app bash -c '
        set -e
        cd /var/www/html
        mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions \
                 storage/framework/testing storage/framework/views storage/logs bootstrap/cache database
        chmod -R ug+rwX storage bootstrap/cache
        [ -f database/database.sqlite ] || touch database/database.sqlite
        chmod 775 database
        chmod 664 database/database.sqlite
    ' || warn "Could not fix every permission (files owned by another user?). Try: sudo chown -R \$(id -u):\$(id -g) src"
}

# =============================================================================
FRESH_INSTALL=0
FRESH_ENV_CONFIGURED=0
LARAVEL_ENV_CREATED=0

check_prerequisites
ensure_env_file
mkdir -p src                         # must exist before Docker starts, or Docker creates it as root
docker compose config -q || die "docker-compose.yml failed validation (see message above)."
warn_if_ports_busy

info "Building Docker images"
dc build
info "Starting MySQL"
dc up -d mysql
wait_for_mysql
info "Starting all containers"
dc up -d
ok "Containers are up"

if [ -f src/artisan ]; then
    info "Existing Laravel application detected in src/ (application files are not modified)"
else
    install_fresh_laravel
fi

configure_laravel_env

info "Installing Composer dependencies"
app composer install --no-interaction --prefer-dist

if ! grep -qE '^APP_KEY=.+' src/.env; then
    info "Generating APP_KEY"
    app php artisan key:generate --ansi
fi

fix_permissions
app php artisan config:clear --ansi >/dev/null 2>&1 || true

if [ "$FRESH_INSTALL" = 1 ]; then
    info "Running initial migrations (fresh project only)"
    app php artisan migrate --force --ansi
else
    warn "Existing project: migrations were NOT run. Run 'make artisan cmd=\"migrate\"' when ready."
fi

# ---------- 15. summary ------------------------------------------------------
APP_PORT=$(env_get .env APP_PORT);            MAILPIT_WEB_PORT=$(env_get .env MAILPIT_WEB_PORT)
MYSQL_PORT=$(env_get .env MYSQL_PORT);        MAILPIT_SMTP_PORT=$(env_get .env MAILPIT_SMTP_PORT)
BIND=$(env_get .env BIND_ADDRESS)
cat <<EOF

${C_GRN}${C_BLD}Setup complete.${C_OFF}

  Application   http://localhost:${APP_PORT}
  Mailpit UI    http://localhost:${MAILPIT_WEB_PORT}      (SMTP: mailpit:1025 in Docker, ${BIND}:${MAILPIT_SMTP_PORT} on host)
  MySQL         ${BIND}:${MYSQL_PORT}   database: $(env_get .env DB_DATABASE)   user: $(env_get .env DB_USERNAME)
                (password: see DB_PASSWORD in .env)

Useful commands (everything runs inside Docker):
  make help                       list all commands
  make artisan cmd="migrate"      run Artisan
  make composer cmd="require x/y" run Composer
  make npm cmd="install"          run npm      |  make npm-dev   Vite dev server
  make bash                       shell in the app container
  make xdebug-on / xdebug-off     toggle step debugging
  make logs | make status | make down
EOF
if [ "$FRESH_INSTALL" = 1 ]; then
    printf '\nNext: make npm cmd="install" && make npm-build   (or make npm-dev while developing)\n'
fi
