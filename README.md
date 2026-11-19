# Laravel Docker Starter Template

A reusable local development environment for Laravel on **Ubuntu + Docker**.
PHP, Composer, Node.js and npm live **only inside containers**. Your host needs just Docker, Docker Compose V2, Git and basic Linux tools.

| Service   | Image / stack                              | Host port (default)        |
|-----------|--------------------------------------------|----------------------------|
| `app`     | PHP 8.3-FPM, Composer 2, Node 22 LTS, npm, Xdebug 3 | Vite: `5173`      |
| `nginx`   | `nginx:stable-alpine`                      | `8080` → http://localhost:8080 |
| `mysql`   | `mysql:8.4`, named volume                  | `3307` → container `3306`  |
| `mailpit` | `axllent/mailpit`                          | UI `8025`, SMTP `1025`     |

SQLite works through the PHP extensions (no extra container). All ports are bound to `127.0.0.1` by default.

```
sandbox-laravel/
├── docker/
│   ├── php/ (Dockerfile, php.ini, conf.d/xdebug.ini)
│   └── nginx/default.conf
├── src/                  ← the Laravel application lives here
├── .env.example          ← tracked template; .env is generated and git-ignored
├── docker-compose.yml
├── Makefile
├── setup.sh
└── README.md
```

---

## 1. Prerequisites

* Ubuntu (22.04 / 24.04 tested layout), Docker Engine and the Compose V2 plugin, Git.
* Your user must be able to run Docker without `sudo`.

```bash
# Install Docker from Docker's official apt repository:
#   https://docs.docker.com/engine/install/ubuntu/
sudo usermod -aG docker "$USER"      # then log out and back in
docker --version && docker compose version
```

Do **not** install PHP, Composer, Node or npm on the host.

## 2. Initial installation

```bash
cd ~/projects/sandbox-laravel      # the directory name becomes the PROJECT_NAME
./setup.sh
```

## 3. Project initialization

`setup.sh` performs these steps and is **idempotent** (safe to re-run):

1. Checks Docker and Docker Compose V2.
2. Derives a valid `PROJECT_NAME` from the directory name.
3. Creates `.env` from `.env.example` (only if missing), sets your `HOST_UID/GID`, and generates random `DB_PASSWORD` / `DB_ROOT_PASSWORD` (only if empty). Existing values are never overwritten; new template keys are appended.
4. Builds the images, starts MySQL and waits for its healthcheck, then starts everything.
5. **Fresh project** (`src/` has no `artisan`): creates Laravel `LARAVEL_VERSION` (default 13) inside `src/` and runs the initial migrations.
   **Existing project** (`src/artisan` exists): application files are not touched and no migrations run.
6. Configures `src/.env` once (MySQL host `mysql`, Mailpit host `mailpit`, `APP_URL`). A marker line is added, so later runs leave your edits alone. An existing `src/.env` is backed up to `src/.env.pre-docker-template` first.
7. Runs `composer install`, generates `APP_KEY` if missing, fixes `storage`, `bootstrap/cache` and SQLite permissions.
8. Prints URLs and useful commands.

Then install front-end dependencies:

```bash
make npm cmd="install"
make npm-build        # or: make npm-dev  (Vite dev server with HMR)
```

To use an **existing Laravel app**, copy it into `src/` (so `src/artisan` exists) and run `./setup.sh`.

## 4. Starting and stopping

```bash
make up         # start in background        make status   # containers + URLs
make down       # stop & remove containers   make logs     # follow logs (make logs svc=nginx)
make restart    # restart                    make build    # rebuild images and recreate
make clean      # = down; volumes (database) are KEPT
make destroy    # DESTRUCTIVE: also deletes volumes; asks you to type the project name
```

`make help` lists every target.

## 5. Artisan

```bash
make artisan cmd="migrate"
make artisan cmd="make:model Post -mfc"
make artisan cmd="tinker"
make test                       # php artisan test  (make test cmd="--filter=UserTest")
make bash                       # interactive shell in the app container
```

## 6. Composer

```bash
make composer cmd="install"
make composer cmd="require laravel/sanctum"
```

## 7. npm

```bash
make npm cmd="install"
make npm cmd="install -D tailwindcss"
make npm-dev        # Vite dev server on http://localhost:5173 (published by the app container)
make npm-build
```

If hot reload doesn't connect, set this in `src/vite.config.js`:

```js
server: { host: '0.0.0.0', hmr: { host: 'localhost' } },
```

## 8. Database access through PhpStorm

*Database tool window → + → Data Source → MySQL*

| Field    | Value                                            |
|----------|--------------------------------------------------|
| Host     | `127.0.0.1`                                      |
| Port     | `MYSQL_PORT` from `.env` (default `3307`)        |
| User     | `DB_USERNAME` (default `laravel`)                |
| Password | `DB_PASSWORD` from `.env`                        |
| Database | `DB_DATABASE` from `.env`                        |

Download the driver when prompted, then **Test Connection**. Command-line: `make mysql`.
Inside Docker, Laravel uses host `mysql`, port `3306`.

## 9. SQLite configuration

SQLite uses the PHP `pdo_sqlite`/`sqlite3` extensions already in the image. Edit **`src/.env`**:

```dotenv
DB_CONNECTION=sqlite
# DB_DATABASE defaults to database/database.sqlite - remove or comment the MySQL values:
# DB_HOST=mysql
# DB_PORT=3306
# DB_USERNAME=laravel
# DB_PASSWORD=...
```

(Remove/comment `DB_DATABASE` unless it is a path to your SQLite file.) Then:

```bash
make artisan cmd="config:clear"
make artisan cmd="migrate"
```

`setup.sh` creates `src/database/database.sqlite` with mode `664` and the `database/` directory with `775` (SQLite needs a writable directory for its journal). To go back to MySQL, restore `DB_CONNECTION=mysql` and the values above (they are also in the project `.env`).

## 10. Mailpit

* Laravel settings (already applied to `src/.env`):
  `MAIL_MAILER=smtp`, `MAIL_HOST=mailpit`, `MAIL_PORT=1025`, no username/password/encryption.
* Web UI: **http://localhost:8025** (`MAILPIT_WEB_PORT`).
* From the host the SMTP port is `127.0.0.1:1025` (`MAILPIT_SMTP_PORT`).
* Try it: `make artisan cmd="tinker"` then
  `Mail::raw('Hello', fn($m) => $m->to('test@example.com')->subject('Test'));`
  Open the UI to read, search and inspect headers, HTML/text parts and attachments. Mailpit never delivers mail externally.

## 11. Xdebug and PhpStorm

Xdebug 3 is installed with `mode=off` (almost zero overhead). Toggle it:

```bash
make xdebug-on     # sets XDEBUG_MODE=debug in .env and recreates the app container
make xdebug-off
```

Configurable in `.env`: `XDEBUG_MODE`, `XDEBUG_PORT` (9003), `XDEBUG_CLIENT_HOST` (`host.docker.internal`, mapped to the host via `host-gateway`), `XDEBUG_IDEKEY` (`PHPSTORM`).

**PhpStorm setup**

1. **Docker**: *Settings → Build, Execution, Deployment → Docker* → add **Docker** (Unix socket).
2. **PHP CLI interpreter via Docker Compose**: *Settings → PHP → CLI Interpreter → … → + → From Docker, Vagrant, VM…* → **Docker Compose**. Configuration files: `docker-compose.yml`; Service: `app`; Lifecycle: *Connect to existing container*. PhpStorm should detect PHP 8.3 and Xdebug.
3. **Composer**: *Settings → PHP → Composer* → *Execute using: Remote interpreter* → pick the interpreter above. Path to `composer.json`: `src/composer.json`.
4. **PHPUnit**: *Settings → PHP → Test Frameworks → + → PHPUnit by Remote Interpreter* → *Use Composer autoloader*, path `/var/www/html/vendor/autoload.php`; default configuration file `/var/www/html/phpunit.xml`.
5. **Debug port**: *Settings → PHP → Debug* → Xdebug debug port `9003`; tick *Can accept external connections*.
6. **Server and path mappings** (*Settings → PHP → Servers*):
   * **Name**: exactly your `PROJECT_NAME` (the container sets `PHP_IDE_CONFIG=serverName=<PROJECT_NAME>`)
   * **Host**: `localhost`, **Port**: `APP_PORT` (8080), **Debugger**: Xdebug
   * ✔ *Use path mappings*: `<project>/src` → `/var/www/html`
7. Click **Start Listening for PHP Debug Connections**, set a breakpoint, run `make xdebug-on`, load http://localhost:8080. CLI/Artisan/tests debug the same way (run them from PhpStorm, or `make artisan ...` while listening).

If the IDE never connects: check the firewall allows Docker → host on 9003
(`sudo ufw allow from 172.16.0.0/12 to any port 9003 proto tcp`), and that Xdebug is on (`make bash` → `php -v` shows *with Xdebug*).

## 12. Changing PHP versions

Edit `PHP_VERSION` in `.env` (e.g. `8.2`, `8.4`) and rebuild:

```bash
make build
make composer cmd="update"      # only if dependencies need to match
```

Images are tagged `<PROJECT_NAME>-app:php<version>`. Laravel 12 needs PHP ≥ 8.2, Laravel 13 needs PHP ≥ 8.3. Node: change `NODE_MAJOR` and `make build`.

## 13. Changing Laravel versions

`LARAVEL_VERSION` (default `13`) only matters when creating a **new** project in an empty `src/`. Accepted: `13`, `12`, `13.1`, `latest`, or any Composer constraint (e.g. `~11.0`). Set it in `.env` before the first `./setup.sh`.
For an existing project, upgrade the normal way (`make composer cmd="require laravel/framework:^12.0 -W"`) following the Laravel upgrade guide.

## 14. Changing ports

Edit `APP_PORT`, `MYSQL_PORT`, `MAILPIT_WEB_PORT`, `MAILPIT_SMTP_PORT`, `VITE_PORT` in `.env`, then `make up`. If you change `APP_PORT`, also update `APP_URL` in `src/.env`. `BIND_ADDRESS=0.0.0.0` exposes the ports to your network (not recommended). Container-internal ports never change, so `DB_PORT=3306` and `MAIL_PORT=1025` in `src/.env` stay as they are.

## 15. Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied` talking to Docker | `sudo usermod -aG docker $USER`, log out/in. |
| `port is already allocated` | Change the port in `.env` (e.g. `MYSQL_PORT=3308`), `make up`. A host MySQL often occupies 3306. |
| Files in `src/` owned by root or not writable | `HOST_UID/HOST_GID` in `.env` must equal `id -u` / `id -g`; then `make build`. Fix existing files: `sudo chown -R $(id -u):$(id -g) src`. |
| `SQLSTATE[HY000] [1045] Access denied` | MySQL only reads credentials when the volume is **first** created. Either put the old password back, or (data loss!) `make destroy` then `./setup.sh`. Also make sure `src/.env` matches `.env`. |
| `Connection refused` to MySQL from Laravel | Use `DB_HOST=mysql`, `DB_PORT=3306` (not `127.0.0.1` / `MYSQL_PORT`) inside Docker. |
| 502 Bad Gateway | `make logs svc=app`; ensure `src/public/index.php` exists and the app container is healthy (`make status`). |
| `affected by security advisories` during `composer create-project` | The chosen Laravel version is end-of-life (Laravel 11 since March 2026). Set `LARAVEL_VERSION=13` (or `12`) in `.env` and re-run `./setup.sh`. |
| `Vite manifest not found` | Run `make npm cmd="install"` then `make npm-build` (or `make npm-dev`). |
| Config changes not picked up | `make artisan cmd="config:clear"`. |
| `.env` changes not applied to containers | `make up` (Compose recreates changed containers). |
| Php.ini / Xdebug ini edits ignored | Those files are baked into the image: `make build`. |
| Xdebug not connecting | See section 11; confirm `XDEBUG_MODE=debug`, the server name equals `PROJECT_NAME`, path mapping is set. |
| Composer/npm are slow on the first run | Caches are stored in named volumes and reused afterwards. |
| `make` exec targets say container not running | They auto-start the stack; otherwise run `make up` and check `make logs`. |

## 16. Creating new projects from the template

```bash
cp -r sandbox-laravel ~/projects/my-shop        # or: git clone <template> ~/projects/my-shop
cd ~/projects/my-shop
rm -rf .git && git init                         # new history (if copied from a git repo)
rm -f .env                                      # only if you copied a configured project
./setup.sh
```

The directory name (`my-shop`) becomes `PROJECT_NAME`, so containers (`my-shop-app`, …), the network (`my-shop_network`) and volumes (`my-shop_mysql-data`, …) are independent from every other copy. Give simultaneous projects different ports in `.env` (setup.sh warns if a port is busy).

To start from the template cleanly, make sure `src/` only contains `.gitkeep` and `.env` is absent.

## 17. Persistent database storage and backups

* Data lives in the named volume `<PROJECT_NAME>_mysql-data`. It survives `make down`, `make clean`, rebuilds and reboots. Only `make destroy` (or `docker volume rm` / `docker compose down -v`) removes it.
* Backup / restore:

```bash
make db-backup                                   # → backups/<project>-<timestamp>.sql.gz (git-ignored)
make db-restore file=backups/my-shop-2025....sql.gz
```

* Inspect volumes: `docker volume ls --filter name=<PROJECT_NAME>`.
* The `src/` directory is a bind mount, so application code is always plain files on your host (editable in PhpStorm).

---

## Security notes

* `.env` is created with mode `600` and is git-ignored; never commit secrets. Passwords are random per project.
* Ports bind to `127.0.0.1`; MySQL and Mailpit are dev tools, not production services.
* Containers are not privileged; the PHP container runs as an unprivileged user, and nginx mounts `src/` read-only.

## Generated files

`docker-compose.yml`, `Makefile`, `setup.sh`, `.env.example`, `.gitignore`, `README.md`, `docker/php/{Dockerfile,php.ini,conf.d/xdebug.ini}`, `docker/nginx/default.conf`, `src/.gitkeep`.
