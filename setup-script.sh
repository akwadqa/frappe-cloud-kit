#!/usr/bin/env bash
# Frappe Framework v16 (latest) dev container setup — framework only, no extra apps.
# Reusable: add it as the environment's setup script; every new session gets a ready bench.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ===== CONFIG: fill these in. Environment variables with the same names override them. =====
# (Cloud setup scripts can't read the environment's saved variables, so set the values here.)
FRAPPE_BENCH_DIR="${FRAPPE_BENCH_DIR:-}"                # e.g. /root/frappe-bench
FRAPPE_SITE="${FRAPPE_SITE:-}"                          # e.g. myproject.localhost
FRAPPE_DB_ROOT_PASSWORD="${FRAPPE_DB_ROOT_PASSWORD:-}"  # MariaDB root password
FRAPPE_ADMIN_PASSWORD="${FRAPPE_ADMIN_PASSWORD:-}"      # site Administrator password
# ===========================================================================================

missing=""
for v in FRAPPE_BENCH_DIR FRAPPE_SITE FRAPPE_DB_ROOT_PASSWORD FRAPPE_ADMIN_PASSWORD; do
  [ -n "${!v}" ] || missing="$missing $v"
done
[ -z "$missing" ] || { echo "ERROR: set these in the CONFIG block:$missing" >&2; exit 1; }

# Official v16 requirements: Debian 13+ / Ubuntu 24.04+, MariaDB 11.8, Python 3.14, Node 24,
# Redis 6+, Yarn 1.22+, pip 25.3+, Chromium (PDFs), cron.
. /etc/os-release
case "$ID" in
  ubuntu) dpkg --compare-versions "$VERSION_ID" ge 24.04 ;;
  debian) dpkg --compare-versions "$VERSION_ID" ge 13 ;;
  *) false ;;
esac || { echo "ERROR: Frappe v16 needs Debian 13+ or Ubuntu 24.04+ (found $PRETTY_NAME)" >&2; exit 1; }

# 1. System packages (official list + build tools + Chromium runtime libs), MariaDB 11.8
apt-get update -qq
apt-get install -y -qq curl git pkg-config build-essential libmariadb-dev redis-server cron fontconfig \
  libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 \
  libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64
# Distro MariaDB is 10.11 on Ubuntu 24.04, so use MariaDB's official 11.8 repository
curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=mariadb-11.8
apt-get install -y -qq mariadb-server mariadb-client

# 2. Node 24 via nvm and Yarn (official method). Links in /usr/local/bin make them work in every shell.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
set +eu; . "$NVM_DIR/nvm.sh"; nvm install 24; nvm alias default 24; set -eu
npm install -g yarn
NODE_BIN="$(dirname "$(nvm which 24)")"
ln -sf "$NODE_BIN"/{node,npm,npx,yarn} /usr/local/bin/

# 3. MariaDB settings Frappe expects, start it, then the mariadb-secure-installation steps
mkdir -p /etc/mysql/mariadb.conf.d
cat >/etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF
service mariadb start || (mysqld_safe >/dev/null 2>&1 &)
for i in $(seq 1 30); do mariadb-admin ping --silent 2>/dev/null && break; sleep 1; done
mariadb -uroot -e "
  ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${FRAPPE_DB_ROOT_PASSWORD//\'/\'\'}');
  DELETE FROM mysql.global_priv WHERE User='';
  DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
  DROP DATABASE IF EXISTS test;
  FLUSH PRIVILEGES;"
service redis-server start || true
service cron start || true

# 4. Python 3.14 via uv (official method) and the bench CLI
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.14 --default
uv tool install --upgrade --python 3.14 frappe-bench
bench --version

# 5. Bench on the version-16 branch (latest v16 release), pip 25.3+, Chromium, and the site
if [ ! -d "$FRAPPE_BENCH_DIR/apps/frappe" ]; then
  mkdir -p "$(dirname "$FRAPPE_BENCH_DIR")"
  # bench refuses to run as root unless frappe_user is set. This container is single-user
  # and runs as root, so run init from a folder whose config names root as the user.
  SHIM="$(mktemp -d)"; mkdir -p "$SHIM/sites"
  echo '{"frappe_user":"root"}' >"$SHIM/sites/common_site_config.json"
  (cd "$SHIM" && bench init "$FRAPPE_BENCH_DIR" --frappe-branch version-16 --python "$(uv python find 3.14)")
  rm -rf "$SHIM"
fi
cd "$FRAPPE_BENCH_DIR"
uv pip install --python "$FRAPPE_BENCH_DIR/env/bin/python" -U "pip>=25.3"
bench setup-chrome || echo "WARNING: bench setup-chrome failed; bench will download Chromium on first PDF"
if [ ! -d "sites/$FRAPPE_SITE" ]; then
  bench new-site "$FRAPPE_SITE" --db-root-password "$FRAPPE_DB_ROOT_PASSWORD" \
    --admin-password "$FRAPPE_ADMIN_PASSWORD"
  bench --site "$FRAPPE_SITE" set-config developer_mode 1
  bench --site "$FRAPPE_SITE" set-config allow_tests true
  bench --site "$FRAPPE_SITE" enable-scheduler
fi
bench use "$FRAPPE_SITE"

# 6. Settings for the session: paths are public, passwords go in a root-only file
cat >/etc/frappe-dev.env <<EOF
FRAPPE_BENCH_DIR="$FRAPPE_BENCH_DIR"
FRAPPE_SITE="$FRAPPE_SITE"
EOF
umask 077
printf 'FRAPPE_DB_ROOT_PASSWORD=%q\nFRAPPE_ADMIN_PASSWORD=%q\n' \
  "$FRAPPE_DB_ROOT_PASSWORD" "$FRAPPE_ADMIN_PASSWORD" >/root/.frappe-dev-secrets
umask 022

# 7. Session helpers: start services, create extra sites (passwords never shown)
cat >/usr/local/bin/frappe-start <<'EOF'
#!/usr/bin/env bash
# Starts MariaDB, Redis and cron. Safe to run repeatedly.
service mariadb start >/dev/null 2>&1 || (mysqld_safe >/dev/null 2>&1 &)
service redis-server start >/dev/null 2>&1 || true
service cron start >/dev/null 2>&1 || true
for i in $(seq 1 30); do mariadb-admin ping --silent 2>/dev/null && break; sleep 1; done
source /etc/frappe-dev.env
echo "Services up. Bench: $FRAPPE_BENCH_DIR  Site: $FRAPPE_SITE  ->  bench start (port 8000)"
EOF
cat >/usr/local/bin/frappe-new-site <<'EOF'
#!/usr/bin/env bash
# Usage: frappe-new-site <site-name>   (dev site with developer mode, configured passwords)
set -euo pipefail
[ -n "${1:-}" ] || { echo "Usage: frappe-new-site <site-name>" >&2; exit 1; }
source /etc/frappe-dev.env; source /root/.frappe-dev-secrets
export PATH="$HOME/.local/bin:$PATH"
cd "$FRAPPE_BENCH_DIR"
bench new-site "$1" --db-root-password "$FRAPPE_DB_ROOT_PASSWORD" --admin-password "$FRAPPE_ADMIN_PASSWORD"
bench --site "$1" set-config developer_mode 1
bench --site "$1" set-config allow_tests true
EOF
chmod 755 /usr/local/bin/frappe-start /usr/local/bin/frappe-new-site

# 8. Session kickoff instructions for Claude (loaded by every new session via ~/.claude/CLAUDE.md)
mkdir -p "$HOME/.claude/skills"
cat >"$HOME/.claude/frappe-session.md" <<EOF
# Frappe v16 dev container: session kickoff (REQUIRED)

Frappe Framework v16 is installed, with no apps.
- Bench directory: $FRAPPE_BENCH_DIR
- Default site: $FRAPPE_SITE (developer mode on). Login: Administrator.
- Passwords are in /root/.frappe-dev-secrets. Never print, echo, commit or copy them anywhere;
  use \`frappe-new-site <name>\` to create sites instead of typing passwords.

## First command in every session
Run \`frappe-start\` (starts MariaDB and Redis).

## Before doing ANY other work in a new session, ask the user for the following, all in one message, and wait for the answers:
1. Project name
2. Project description: goal, users, web app and/or mobile backend scope
3. Skills to load: a local path, a git repo URL, or "none"
4. App(s): for each one, the app name and whether it is NEW (bench new-app) or EXISTING
5. For existing apps: the repo URL and branch
6. Any extra sites beyond $FRAPPE_SITE, and any extra Frappe apps to install (default: none)
7. Git author name/email for commits, and the branch to work on

Skip a question only if the app repo's CLAUDE.md (or PROJECT.md) already answers it.
Confirm the answers in a short summary, then set up as follows (from $FRAPPE_BENCH_DIR).

## Setup steps after the answers are in
- Skills: for a git URL, clone it to ~/skills-src/<name>. For each folder that has a SKILL.md, symlink
  it into ~/.claude/skills/<skill-name>. Read each SKILL.md now so it applies in this session.
- Existing app: \`bench get-app <repo-url> --branch <branch>\`
- New app: \`bench new-app <app_name>\`, then \`git init\` it in apps/<app_name>
- Extra site: \`frappe-new-site <site>\`
- Install: \`bench --site <site> install-app <app_name>\`, then \`bench --site <site> migrate\`
- Save the project name, description, skills source and app/repo info (no passwords) to apps/<app_name>/CLAUDE.md
  and commit it, so the next session can reuse it and skip those questions.
- Run: \`bench start\` (port 8000). Tests: \`bench --site <site> run-tests --app <app_name>\`
- Mobile backend: REST at /api/resource/<DocType> and /api/method/<dotted.path>; use token auth (API key/secret).
EOF
touch "$HOME/.claude/CLAUDE.md"
grep -qF '@~/.claude/frappe-session.md' "$HOME/.claude/CLAUDE.md" ||
  echo '@~/.claude/frappe-session.md' >>"$HOME/.claude/CLAUDE.md"

echo "Frappe v16 ready: bench=$FRAPPE_BENCH_DIR site=$FRAPPE_SITE. In each session run: frappe-start"
