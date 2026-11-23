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
| AWS CLI v2 and Session Manager plugin | — | AWS's installers (for SSM sessions to servers) |
| frappectl | — | `uv tool install frappectl` (a Frappe site's API from the command line) |

## Setup for each environment

1. In the Claude app, open the cloud environment menu in the session title bar, then
   **Add environment** (or **Edit** an existing one).
2. **Network access:** the setup downloads from `github.com`, `raw.githubusercontent.com` (nvm),
   `nodejs.org`, `r.mariadb.com` and `dlm.mariadb.com` (MariaDB), `astral.sh` (uv),
   `awscli.amazonaws.com` and `s3.amazonaws.com` (AWS tools), plus the usual package managers. If your network policy is restricted, allow these hosts.
3. **Repositories:** this kit is public, so it doesn't need to be selected. Select only your
   private app repos.
4. **Setup script:** paste this loader and fill in the four values (see `.env.example`):

   ```bash
   FRAPPE_BENCH_DIR="/home/user/frappe-bench"
   FRAPPE_SITE="myproject.localhost"
   FRAPPE_DB_ROOT_PASSWORD="change-me"
   FRAPPE_ADMIN_PASSWORD="change-me"
   export GIT_TERMINAL_PROMPT=0   # fail with an error instead of waiting for a GitHub login
   rm -rf /opt/frappe-cloud-kit
   git clone --depth 1 https://github.com/akwadqa/frappe-cloud-kit /opt/frappe-cloud-kit
   source /opt/frappe-cloud-kit/setup-script.sh
   ```

   Set the values in the loader, not under Environment variables: setup scripts can't read
   the environment's saved variables. Keep the bench under `/home/user` so the Claude app can
   open its files. Every environment picks up kit updates on its next session.
   Alternatively, paste the whole of `setup-script.sh` and fill in its CONFIG block.

5. Start a new session.

## Every session

- Claude runs `frappe-start` first (starts MariaDB, Redis and cron). It then reads the app repo's
  `CLAUDE.md` and any user-level instructions, and asks only what they don't answer: the project,
  the apps and their repos, skills to load, extra sites, and git details.
- An app repo checked out in the session is linked into the bench (`apps/<app>`), not cloned again.
- Claude records what it learned in the repo's `CLAUDE.md`, on a branch through your usual review,
  so later sessions skip the questions.
- `frappe-new-site <name>` creates another dev site using the configured passwords.
- Start the server with `bench start` (port 8000). Claude tells the Claude app about port 8000,
  so you can open the site in the preview pane. `Administrator` is for setting up; check features as a
  user who has only the app's roles.
- Passwords are kept in `/root/.frappe-dev-secrets` (root-only); Claude never prints or commits them.

## What persists and what doesn't

Each session is a fresh container, and the setup script rebuilds the bench every time.
Your code persists only through git, so push app changes to their repos.
Site data does not persist: seed what the app needs from its setup code (`after_install`,
`after_migrate`) and its tests' factories, or keep a backup and restore it.
