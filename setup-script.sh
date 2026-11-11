#!/usr/bin/env bash
# =============================================================================
#  Frappe Cloud Kit — environment setup script for Claude Code cloud sessions
#  Use either way in: environment settings -> Setup script
#   a) paste this whole file and edit the CONFIG defaults below, or
#   b) set PROJECT/APPS/... and then: source <path-to-this-file>  (see README)
# =============================================================================

# ----------------------------- CONFIG ---------------------------------------
# Each value can be set before this file runs (e.g. by a short loader in the
# environment's setup script); otherwise the default after ":-" is used.
PROJECT="${PROJECT:-project-a}"          # bench becomes /home/user/<PROJECT>-bench
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"   # latest Frappe v16 (branch tracks newest v16.x)

# Apps fetched AND installed on the site. Format: name-or-git-url[#branch]
# Official apps without "#branch" default to $FRAPPE_BRANCH.
APPS="${APPS:-erpnext hrms}"

# Your custom apps (fetched into apps/ so Claude can read/scan them).
# Format: git-url[#branch]. Private repos must be selected under
# "Repositories" in the environment settings.
CUSTOM_APPS="${CUSTOM_APPS:-}"
INSTALL_CUSTOM_APPS="${INSTALL_CUSTOM_APPS:-no}"     # "yes" = also install them on the site

ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"       # site Administrator password (dev only)
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"      # local MariaDB root password (dev only)
# -----------------------------------------------------------------------------

set -uo pipefail
cd /home/user 2>/dev/null || cd /
LOG=/var/log/frappe-kit.log
exec > >(tee -a "$LOG") 2>&1
step() { echo -e "\n==> [frappe-kit] $*"; }
die()  { echo "!! [frappe-kit] $*"; exit 1; }

BENCH_DIR="/home/user/${PROJECT}-bench"
SITE="${PROJECT}.localhost"
NODE_MAJOR=24
PY_VER=3.14
LOCALBIN=/root/.local/bin
mkdir -p "$LOCALBIN"
export PATH="$LOCALBIN:$PATH"

# --- 1. System packages ------------------------------------------------------
step "Installing system packages (MariaDB, Redis, build deps)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || die "apt-get update failed"
apt-get install -y -qq mariadb-server mariadb-client libmariadb-dev pkg-config \
  redis-server xvfb libfontconfig cron git curl build-essential >/dev/null \
  || die "apt-get install failed"

cat >/etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
[mysql]
default-character-set = utf8mb4
EOF
service mariadb restart || die "MariaDB failed to start"
mysql -h127.0.0.1 -uroot -p"$DB_ROOT_PASSWORD" -e "select 1" >/dev/null 2>&1 || \
  mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$DB_ROOT_PASSWORD'); FLUSH PRIVILEGES;" \
  || die "could not set MariaDB root password"

# --- 2. Python 3.14 + Node 24 + yarn ----------------------------------------
step "Installing Python $PY_VER (uv) and Node $NODE_MAJOR"
command -v uv >/dev/null || pip3 install -q uv || die "uv install failed"
uv python install "$PY_VER" >/dev/null || die "python $PY_VER install failed"
PYTHON_BIN="$(uv python find "$PY_VER")"

if ! node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
  NODE_TGZ=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" \
             | awk '/linux-x64.tar.xz$/{print $2}')
  [ -n "$NODE_TGZ" ] || die "could not resolve Node $NODE_MAJOR download"
  rm -rf "/opt/node${NODE_MAJOR}" && mkdir -p "/opt/node${NODE_MAJOR}"
  curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/$NODE_TGZ" \
    | tar -xJ -C "/opt/node${NODE_MAJOR}" --strip-components=1 || die "node download failed"
  for b in node npm npx corepack; do ln -sf "/opt/node${NODE_MAJOR}/bin/$b" "$LOCALBIN/$b"; done
fi
npm install -g -s yarn >/dev/null || die "yarn install failed"
ln -sf "/opt/node${NODE_MAJOR}/bin/yarn" "$LOCALBIN/yarn"
node --version; yarn --version

# --- 3. bench CLI ------------------------------------------------------------
step "Installing frappe-bench"
uv tool install -q frappe-bench >/dev/null 2>&1 || uv tool upgrade frappe-bench >/dev/null
command -v bench >/dev/null || die "bench not on PATH"

# --- 4. Bench + Frappe -------------------------------------------------------
cd /home/user
if [ ! -d "$BENCH_DIR/apps/frappe" ]; then
  step "Creating bench $BENCH_DIR (Frappe $FRAPPE_BRANCH)"
  # bench refuses to run as root unless frappe_user is set; this container is
  # single-user and runs everything as root, so tell bench that root is the user.
  SHIM=$(mktemp -d) && mkdir -p "$SHIM/sites" \
    && echo '{"frappe_user":"root"}' > "$SHIM/sites/common_site_config.json"
  (cd "$SHIM" && bench init "$BENCH_DIR" --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN") \
    || die "bench init failed"
  rm -rf "$SHIM"
else
  step "Bench already exists at $BENCH_DIR; reusing it"
fi
cd "$BENCH_DIR" || die "no bench dir"

get_app() {  # $1 = name-or-url[#branch], $2 = default branch ("" = repo default)
  local spec="$1" src="${1%%#*}" branch=""
  # bare names (erpnext, hrms, ...) -> official repo URL; bench's own name lookup
  # needs the GitHub API, which the sandbox network blocks.
  [[ "$src" != */* ]] && src="https://github.com/frappe/$src"
  [[ "$spec" == *#* ]] && branch="${spec#*#}" || branch="$2"
  local name; name=$(basename "$src" .git)
  if [ -d "apps/$name" ]; then echo "$name"; return 0; fi
  echo "   fetching $src ${branch:+(branch $branch)}" >&2
  if bench get-app ${branch:+--branch "$branch"} --skip-assets "$src" >&2; then
    tail -1 sites/apps.txt   # real app name as registered by bench
  else
    echo "!! failed to fetch $src (private repo not selected in environment?)" >&2
    return 1
  fi
}

INSTALL_LIST=()
step "Fetching apps: $APPS"
for a in $APPS; do n=$(get_app "$a" "$FRAPPE_BRANCH") && INSTALL_LIST+=("$n"); done
if [ -n "$CUSTOM_APPS" ]; then
  step "Fetching custom apps: $CUSTOM_APPS"
  for a in $CUSTOM_APPS; do
    n=$(get_app "$a" "") && [ "$INSTALL_CUSTOM_APPS" = "yes" ] && INSTALL_LIST+=("$n")
  done
fi

# --- 5. Site -------------------------------------------------------------------
service redis-server stop >/dev/null 2>&1 || true   # bench runs its own redis
if [ ! -d "sites/$SITE" ]; then
  step "Creating site $SITE"
  bench new-site "$SITE" --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" || { rm -rf "sites/$SITE"; die "new-site failed"; }
fi
bench use "$SITE"
bench set-config -g developer_mode 1
bench --site "$SITE" set-config host_name "http://localhost:8000"
# install-app needs bench's own redis (cache/queue) running; start them now and
# stop them afterwards so 'bench start' can own these ports later.
for c in config/redis_cache.conf config/redis_queue.conf; do
  redis-server "$c" --daemonize yes >/dev/null
done
for app in "${INSTALL_LIST[@]}"; do
  bench --site "$SITE" list-apps 2>/dev/null | grep -q "^$app\b" && continue
  step "Installing $app on $SITE"
  bench --site "$SITE" install-app "$app" || echo "!! install-app $app failed"
done
step "Building assets"
bench build || echo "!! bench build reported errors"
for p in $(grep -h '^port' config/redis_cache.conf config/redis_queue.conf | awk '{print $2}'); do
  redis-cli -p "$p" shutdown nosave >/dev/null 2>&1 || true
done

# --- 6. Helper command + session hook + Claude memory ---------------------------
step "Writing frappe-start, SessionStart hook, ~/.claude/CLAUDE.md"
cat >/usr/local/bin/frappe-start <<EOF
#!/usr/bin/env bash
# Starts MariaDB + 'bench start' in the background; idempotent.
export PATH="$LOCALBIN:\$PATH"
service mariadb status >/dev/null 2>&1 || service mariadb start >/dev/null 2>&1
if ! curl -s -o /dev/null http://127.0.0.1:8000; then
  cd "$BENCH_DIR" && nohup bench start > /var/log/bench-start.log 2>&1 &
  for i in \$(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8000 && break; sleep 2; done
fi
curl -s -o /dev/null -w "frappe: http://localhost:8000 -> HTTP %{http_code}\n" http://127.0.0.1:8000
EOF
chmod +x /usr/local/bin/frappe-start
ln -sf /usr/local/bin/frappe-start "$LOCALBIN/frappe-start"

mkdir -p /root/.claude
"$PYTHON_BIN" - <<'EOF'
import json, os
p = "/root/.claude/settings.json"
s = json.load(open(p)) if os.path.exists(p) else {}
hooks = s.setdefault("hooks", {}).setdefault("SessionStart", [])
cmd = "frappe-start >/dev/null 2>&1 &"
if not any(h.get("command") == cmd for g in hooks for h in g.get("hooks", [])):
    hooks.append({"hooks": [{"type": "command", "command": cmd}]})
json.dump(s, open(p, "w"), indent=2)
EOF

CUSTOM_NAMES=""
for a in $CUSTOM_APPS; do CUSTOM_NAMES+=" $(basename "${a%%#*}" .git)"; done
cat >/root/.claude/CLAUDE.md <<EOF
# Frappe environment (generated by frappe-cloud-kit setup script)

- Project: **$PROJECT**. Bench: \`$BENCH_DIR\` (Frappe $FRAPPE_BRANCH, Python $PY_VER, Node $NODE_MAJOR).
- Site: \`$SITE\` (default site, served on any hostname). Login: Administrator / see setup script.
- Installed apps: ${INSTALL_LIST[*]:-frappe}
- Custom apps to scan when asked:${CUSTOM_NAMES:- none} — code lives in \`$BENCH_DIR/apps/<app>\`.
- Server: run \`frappe-start\` (idempotent; a SessionStart hook already runs it). Logs: /var/log/bench-start.log.
  Setup log: /var/log/frappe-kit.log.
- After the server is up, report port 8000 with the preview-port tool so the user can open it in the app.
- Verify UI changes with Playwright (Chromium is preinstalled) and send screenshots; run
  \`bench --site $SITE run-tests --app <app>\` for tests. developer_mode is on.
- Everything in this container is ephemeral: commit and push custom-app changes to their git repos.
EOF

step "Done. Bench: $BENCH_DIR  Site: $SITE"
frappe-start || true
