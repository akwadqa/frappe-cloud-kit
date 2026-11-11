# Frappe Cloud Kit

A reusable setup for Claude Code cloud environments. Each new project gets its own cloud
environment. Every session in that environment starts with the following:

- `/home/user/<project>-bench`, running the latest **Frappe v16** (Python 3.14, Node 24, MariaDB, Redis)
- your chosen apps fetched and installed on the site `<project>.localhost`
- your custom apps cloned into `apps/` so Claude can read and scan them
- the site started automatically at `http://localhost:8000`
- a `~/.claude/CLAUDE.md` that tells Claude where everything is

## One-time setup for each new project (A, B, C, ...)

1. In the Claude app, open the cloud environment menu in the session title bar, then
   **Add environment** (or **Edit** an existing one).
2. **Name:** your project name, for example `project-a`.
3. **Network access:** leave package managers allowed. The script also downloads from
   `nodejs.org` and `github.com`.
4. **Repositories:** select any *private* custom-app repos. Without this, the setup script
   can't clone them.
5. **Setup script:** paste this short loader and edit only the first lines:

   ```bash
   PROJECT="project-a"
   APPS="erpnext hrms"                                          # fetched and installed
   CUSTOM_APPS="https://github.com/you/your_app.git#develop"    # fetched for scanning
   INSTALL_CUSTOM_APPS="no"                                     # "yes" also installs them
   rm -rf /opt/frappe-cloud-kit
   git clone --depth 1 https://github.com/akwadqa/frappe-cloud-kit /opt/frappe-cloud-kit
   source /opt/frappe-cloud-kit/setup-script.sh
   ```

   If this kit repo is private, also select it under **Repositories**. Every
   environment then picks up kit updates automatically on its next session.
   Without the repo, you can paste the whole of `setup-script.sh` and edit its
   CONFIG defaults instead.

6. Start a new session in that environment. Setup takes about 10–15 minutes and writes
   its log to `/var/log/frappe-kit.log`.

To change the apps later, edit the environment's setup script. New sessions pick up
the change.

## Day-to-day use

- Start the server with `frappe-start`. A SessionStart hook already runs it for you.
- To see the site:
  - Ask Claude to show the site. Claude registers port 8000 with the Claude app, which
    can open it in a preview pane.
  - Or ask for screenshots: Claude drives Chromium and Playwright inside the container.
- Log in as `Administrator` with the `ADMIN_PASSWORD` from the CONFIG block.

## What persists and what doesn't

Each session is a fresh container. The **setup script** rebuilds the bench every time.
Your **code** persists only through git, so push custom-app changes to their repos.
Site **data** does not persist. Use fixtures in your app, or keep a backup and restore it.

## Public URL (not enabled yet)

A link you can open from any browser needs a tunnel service such as ngrok. The current
network policy blocks tunnel hosts like `trycloudflare.com`. To enable one, add the
tunnel service's domains under the environment's network settings, and store its auth
token as an environment variable. Then ask Claude to add and test a `frappe-share` command.
