# Company Setup Guide — dotnet-cicd-template

This file is the **reference guide** (tables, what each variable means).  
If you have never touched CI/CD, start with the click-by-click walkthrough: [`beginner-walkthrough.en.md`](./beginner-walkthrough.en.md)

You do not edit YML files. All configuration is done in the GitHub UI (Variables / Secrets / Environments) plus a one-time host setup.

Turkish version: [`company-setup.tr.md`](./company-setup.tr.md)

---

## Which path are you on?

| Path | When | Follow |
|---|---|---|
| **Local** | Runner and app on the **same** machine | Steps 1 → 2 (local vars) → 3 (optional `APP_ENV`) → 4 → 5 Local → 6 |
| **Remote** | App on a separate Linux server; runner is GitHub `ubuntu-latest` | Steps 1 → **Server prep (required)** → 2 (remote vars) → 3 (SSH secret) → 4 → 5 Remote → 6 |

Everything below for **remote** is written explicitly in this file:

1. Server `deploy` user + `NOPASSWD: ALL`
2. `SSH_PRIVATE_KEY` secret (ed25519, no passphrase, including BEGIN/END)
3. `SSH_KNOWN_HOSTS` variable (`ssh-keyscan` output)
4. `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`
5. Environments → `production` + required reviewers

---

## Step 1 — Create the repo

1. Open [github.com/Dedmoo/dotnet-cicd-template](https://github.com/Dedmoo/dotnet-cicd-template).
2. **Use this template → Create a new repository**.
3. Move the contents of `templates/` to the **repo root** (`.github/` and `scripts/` must be at root). Keep your .NET project in the same root (`src/...`).

Expected tree:

```
repo-root/
├── .github/
│   ├── actions/build-test/action.yml
│   ├── dependabot.yml
│   └── workflows/
│       ├── continuous-integration.yml
│       ├── reusable-dotnet-build.yml
│       ├── production-deploy.yml
│       └── production-rollback.yml
├── scripts/
│   ├── pipeline.sh
│   ├── ssh-remote.sh
│   ├── verify-health.sh
│   ├── setup-host.sh
│   └── setup-remote-host.sh
└── src/   # your .NET code
```

---

## Remote server prep (remote only — BEFORE Step 2)

Do this **once on the target Linux server** as root/admin. Skip it and deploy fails with `Permission denied` or `sudo: a password is required`.

### U1 — `deploy` user + SSH public key

On your machine (or a secure host), generate a key:

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
# deploy_key      → later GitHub Secret: SSH_PRIVATE_KEY
# deploy_key.pub  → added on the server
```

On the server:

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
# add the public key (paste the single line):
sudo tee /home/deploy/.ssh/authorized_keys < deploy_key.pub
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### U2 — Passwordless `sudo` (`NOPASSWD: ALL`) — required

The pipeline runs every host step as `sudo bash -c "..."`. A narrow command allow-list (`systemctl`, `mkdir`, …) is **not enough** and will break deploy. Add:

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
```

Verify on the server:

```bash
sudo -u deploy sudo -n true && echo "sudo OK"
```

This is full `sudo`. To keep risk lower: use the `deploy` user only on this deployment host; do not reuse it for other tasks.

### U3 — Packages on the server

Typical requirements for deploy and health checks:

```bash
sudo apt-get update
sudo apt-get install -y rsync curl nginx
# .NET runtime/SDK — the version your project targets (e.g. 8)
```

Firewall: keep the SSH port (usually 22) open to the runner; open application ports from `SERVICES` `health_url` so the runner can reach them for health checks.

### U4 — Capture `SSH_KNOWN_HOSTS`

From your machine (or anywhere that can reach the host):

```bash
ssh-keyscan -p 22 <SERVER-IP-OR-HOSTNAME>
```

Copy the **entire** output; paste it as a GitHub Variable in Step 2.

---

## Step 2 — Repository Variables

**GitHub:** Settings → Secrets and variables → Actions → **Variables** → **New repository variable**

### Required for every path

| Variable | Example | Description |
|---|---|---|
| `SERVICES` | see below | One line each: `name\|csproj\|deploy_dir\|service_name\|health_url` |

Single-service example:

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
```

Two services:

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5002
```

**`health_url` format (blue-green):**
- **PORT**: nginx's public port — `setup-host.sh` assigns this port to nginx.
- **PATH**: health endpoint (`/health` etc.) — used by the socket health check.
- **IP**: written for `setup-host.sh` or manual testing; the pipeline checks via socket and ignores the IP part.

Example: `http://203.0.113.10:5001/health` → nginx port `5001`; health path `/health`.

### Local extras

| Variable | Value |
|---|---|
| `DEPLOY_TARGET` | `local` (or leave empty; default is local) |
| `RUNNER_LABEL` | `self-hosted` (whatever your runner label is) |

### Remote — fill this set

| Variable | Required | Value |
|---|---|---|
| `DEPLOY_TARGET` | **Yes** | `remote` |
| `SSH_HOST` | **Yes** | Server IP or hostname |
| `SSH_USER` | **Yes** | `deploy` (the user from U1) |
| `SSH_PORT` | No | Default `22` |
| `SSH_KNOWN_HOSTS` | **Required (remote)** | Full U4 `ssh-keyscan` output |
| `RUNNER_LABEL` | **Yes (recommended)** | `ubuntu-latest` |
| `ARTIFACT_NAME` | No | Default `app-publish` — if you change it, CI and deploy stay in sync |

`SSH_KNOWN_HOSTS` is **required** for remote deploy: if it is empty the pipeline refuses to run (MITM protection — the old `ssh-keyscan` auto-accept fallback was removed). Providing it also avoids connection resets on modern SSH servers (`PerSourcePenalties`).

---

## Step 3 — Repository Secrets

**GitHub:** Settings → Secrets and variables → Actions → **Secrets** → **New repository secret**

| Secret | When | What to paste |
|---|---|---|
| `SSH_PRIVATE_KEY` | **required for remote** | The **entire** `deploy_key` file: `-----BEGIN OPENSSH PRIVATE KEY-----` … `-----END OPENSSH PRIVATE KEY-----`. Passphrase-free (`-N ""`) ed25519. Missing lines = `invalid format`. |
| `APP_ENV` | Optional (local + remote) | `KEY=VALUE` lines (`.env`). Written to each service as `.env` at deploy. |

Never put the private key in Variables — Secrets only.

---

## Step 4 — `production` Environment (required)

**GitHub:** Settings → **Environments** → **New environment** → name it exactly `production`

| Setting | Value | Why |
|---|---|---|
| **Required reviewers** | At least 1 person | No unapproved production deploy |
| **Prevent self-review** | Enabled | Triggering actor cannot approve their own deploy |
| **Deployment branches** | `main` only | No accidental feature-branch production deploys |
| **Wait timer** | 5–15 min (optional) | Cancel window after approval |

Deploy and Rollback bind to this environment. Before approving, read the **`prepare` summary** on the Actions run page (description, commit subject, SHA).

---

## Step 5 — Host setup (one-time)

### Local

Runner = host machine:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
     bash scripts/setup-host.sh
```

Per service: (1) two systemd units (`blue`/`green`, listening on Unix socket), (2) nginx upstream include + public-port server block. Installs nginx automatically if not present. Directories are created on first deploy; services stay up after the first successful deploy.

### Remote

**Finish U1–U2 first** (user + sudoers). Then, from a machine that can SSH and has the private key:

```bash
SSH_HOST=<SERVER-IP> \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://<SERVER-IP>:5001" \
bash scripts/setup-remote-host.sh
```

`health_url` in `SERVICES` must use the same format here. This script runs `setup-host.sh` on the remote host; it creates nginx config and two-color systemd units.

---

## Step 6 — First CI and Deploy

1. Push to `main` → **Continuous Integration** is green in Actions.
2. Actions → **Production Deploy** → **Run workflow** → enter a required description → leave source `ci_artifact` → Run.
3. Reviewer reads the `prepare` summary and approves → deploy runs.
4. If health fails, the nginx switch is **not made**; live traffic is unaffected; the job is marked failed. Fix the issue and trigger a new deploy.

If there is no CI artifact yet (very first setup), use `build_from_source` once; then return to `ci_artifact`.

---

## Files you do not edit

Do not edit these — project values are not written into YML lines:

- `continuous-integration.yml`
- `reusable-dotnet-build.yml`
- `production-deploy.yml`
- `production-rollback.yml`
- `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`

---

## Quick checklist

### Shared
- [ ] Template → new repo; `templates/` at root
- [ ] `SERVICES` correctly formatted
- [ ] `production` environment: required reviewers + prevent self-review + `main` only
- [ ] `nginx` installed on server (`setup-host.sh` installs it or pre-installed)
- [ ] Continuous Integration green at least once
- [ ] Production Deploy triggered with a description / approved

### Remote extras
- [ ] Server has `deploy` user + `authorized_keys`
- [ ] `deploy ALL=(ALL) NOPASSWD: ALL` verified (`sudo -n true`)
- [ ] `rsync` (+ .NET) installed on the server
- [ ] Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`
- [ ] Variable: `SSH_KNOWN_HOSTS` = `ssh-keyscan` output
- [ ] Secret: `SSH_PRIVATE_KEY` = full private key text (BEGIN/END)
- [ ] `SERVICES` health_url PORT = nginx's public port; PATH = health endpoint (`/health`)
- [ ] `nginx` installed on the server (or `setup-host.sh` installed it)
- [ ] `setup-remote-host.sh` run once
