# Frappe Cloud Kit

A reusable setup script for Claude Code cloud environments. Every new session starts with
the latest **Frappe Framework v16**, with no extra apps, built to the official v16 requirements:

| Dependency | Version | Installed with |
|---|---|---|
| OS | Debian 13+ / Ubuntu 24.04+ (checked) | — |
| MariaDB | 11.8 | MariaDB's official repository |
| Python | 3.14 | `uv python install 3.14 --default` |
| Node.js | 24 | nvm v0.40.3 |
| Yarn | 1.22+ | `npm install -g yarn` |
| Redis | 6+ | `redis-server` |
| pip | 25.3+ | upgraded in the bench's Python environment |
| Chromium (PDFs) | — | `bench setup-chrome` |
| cron | — | `cron` |

## Setup for each environment

1. In the Claude app, open the cloud environment menu in the session title bar, then
   **Add environment** (or **Edit** an existing one).
2. **Repositories:** select `akwadqa/frappe-cloud-kit` (it's private), plus any private app repos.
3. **Setup script:** paste this loader and fill in the four values (see `.env.example`):

   ```bash
   FRAPPE_BENCH_DIR="/root/frappe-bench"
   FRAPPE_SITE="myproject.localhost"
   FRAPPE_DB_ROOT_PASSWORD="change-me"
   FRAPPE_ADMIN_PASSWORD="change-me"
   rm -rf /opt/frappe-cloud-kit
   git clone --depth 1 https://github.com/akwadqa/frappe-cloud-kit /opt/frappe-cloud-kit
   source /opt/frappe-cloud-kit/setup-script.sh
   ```

   Set the values in the loader, not under Environment variables: setup scripts can't read
   the environment's saved variables. Every environment picks up kit updates on its next session.
   Without the repo, paste the whole of `setup-script.sh` and fill in its CONFIG block instead.

4. Start a new session.

## Every session

- Claude runs `frappe-start` first (starts MariaDB, Redis and cron), then asks for the project
  name and description, skills to load, apps and their repos, extra sites, and git details.
- Claude saves those answers to `apps/<app>/CLAUDE.md` in your app repo, so later sessions skip them.
- `frappe-new-site <name>` creates another dev site using the configured passwords.
- Start the server with `bench start` (port 8000). Log in as `Administrator`.
- Passwords are kept in `/root/.frappe-dev-secrets` (root-only); Claude never prints or commits them.

## What persists and what doesn't

Each session is a fresh container, and the setup script rebuilds the bench every time.
Your code persists only through git, so push app changes to their repos.
Site data does not persist: use fixtures in your app, or keep a backup and restore it.
