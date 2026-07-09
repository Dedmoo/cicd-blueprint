# Integrate Into Your Own Project — Full Setup Guide (From Scratch)

This guide is for anyone who wants to set up the **dotnet-cicd-template** (blueprint) CI/CD
system on **their own .NET project** from scratch. Even if you have never used CI/CD, GitHub
Actions, Linux or nginx, you can follow it step by step.

> **Note:** `eShopOnWeb` (cicd-eshop) is only a **demo/example**. You do **not** need eShop to use
> this system. Below you connect your own project.

This covers everything **not shown in the video** (server setup, connecting to GitHub, where to
put which code), end to end. The video only shows the daily loop:
`change code → commit → push → CI → approve → live updated`.

Related documents (same information, different formats):
- Click-by-click, remote-server oriented: [`beginner-walkthrough.en.md`](./beginner-walkthrough.en.md)
- Reference tables (which variable does what): [`company-setup.en.md`](./company-setup.en.md)
- Academic/deep playbook: [`dotnet-cicd-template.en.md`](./dotnet-cicd-template.en.md)
- Türkçe sürüm: [`kendi-projene-entegrasyon.tr.md`](./kendi-projene-entegrasyon.tr.md)

---

## Table of contents

1. [What does the system do? (concept)](#1-what-does-the-system-do-concept)
2. [Glossary](#2-glossary)
3. [Two deployment models: local and remote](#3-two-deployment-models-local-and-remote)
4. [Requirements](#4-requirements)
5. [Step A — Get the blueprint into your own repo](#5-step-a--get-the-blueprint-into-your-own-repo)
6. [Step B — Prepare your code (which code goes where)](#6-step-b--prepare-your-code-which-code-goes-where)
7. [Step C — Write the SERVICES line](#7-step-c--write-the-services-line)
8. [Step D — Prepare the server (remote)](#8-step-d--prepare-the-server-remote)
9. [Step E — GitHub settings (Variables / Secrets / Environment)](#9-step-e--github-settings-variables--secrets--environment)
10. [Step F — Runner (who runs the commands?)](#10-step-f--runner-who-runs-the-commands)
11. [Step G — One-time host setup script](#11-step-g--one-time-host-setup-script)
12. [Step H — First CI and first Deploy](#12-step-h--first-ci-and-first-deploy)
13. [Daily workflow (the part shown in the video)](#13-daily-workflow-the-part-shown-in-the-video)
14. [Rollback](#14-rollback)
15. [Security model (what you should know)](#15-security-model-what-you-should-know)
16. [Troubleshooting](#16-troubleshooting)
17. [Setup complete — checklist](#17-setup-complete--checklist)

---

## 1. What does the system do? (concept)

Goal: **ship the new version live with zero downtime.** Users see the update while browsing or on
refresh; there is no "announce and manually restart the app" process.

Flow:

1. You **push** code to GitHub → GitHub **builds + tests** automatically (CI).
2. To go live, an authorized person **starts Deploy manually** and **approves** it.
3. After approval the new version is written to the **idle color (blue/green)** on the server.
4. If the new color **passes the health check**, nginx **silently** switches traffic to it.
5. If the health check **fails**, no switch happens; users keep seeing the old version, uninterrupted.

### What is blue-green?

Each service runs **two copies** on the server: `blue` and `green`. At any moment **only one is
live** (nginx routes to it). Deploy writes to the **idle** color; once health is confirmed nginx
switches to it. The old color stays up — it is the **instant rollback** target.

```
                 nginx (public port)
                        |
              ┌─────────┴─────────┐
        (live) ▼                  ▼ (idle / new version goes here)
       cicd-web-blue.sock   cicd-web-green.sock
        [app v1]              [app v2]
```

---

## 2. Glossary

| Term | Plain meaning |
|---|---|
| **Repo** | Project folder on GitHub |
| **Commit** | "I saved this change" |
| **Push** | Send your saved change to GitHub |
| **CI** | Automatic build + test (Continuous Integration) |
| **Deploy** | Put the new version on the live server |
| **Artifact** | Stored build output produced by CI |
| **Runner** | The machine where Actions commands run |
| **Variable** | Visible setting text on GitHub (e.g. IP) |
| **Secret** | Hidden setting (SSH key); never shown in logs |
| **Environment** | The "ask for approval before going live" gate (`production`) |
| **SSH** | Secure connection to a remote Linux server |
| **nginx** | Web server that routes traffic to the app |
| **systemd** | Linux system that runs the app as a start/stop service |
| **Unix socket** | Local file socket the app listens on instead of a TCP port |

---

## 3. Two deployment models: local and remote

Decide which model you use before setup. The difference is the `DEPLOY_TARGET` variable.

| Model | When | Runner | `DEPLOY_TARGET` |
|---|---|---|---|
| **remote** (recommended) | App runs on a **separate Linux server** | GitHub's `ubuntu-latest` runner (no install) | `remote` |
| **local** | Runner **and** app are on the **same** machine | A **self-hosted** runner you install there | `local` |

- **remote** is right for most companies: GitHub's hosted runner connects to your server via SSH
  and deploys. You do not install a runner on the server.
- **local** is when you run a self-hosted runner on the server itself (e.g. a single-box setup).
  No SSH; the runner works directly on the local machine.

> This guide mostly describes **remote** and notes the local difference where relevant.

---

## 4. Requirements

**Everyone:**
- [ ] A **GitHub account** (free is fine)
- [ ] Permission to copy the template into your account
- [ ] A terminal on your computer (Windows: PowerShell or WSL/Git Bash; Mac/Linux: Terminal)
- [ ] **.NET SDK** (your project's version, e.g. .NET 8) — to build/test locally

**For the remote model:**
- [ ] A **Linux server** (IP/hostname, reachable via SSH)
- [ ] **root/sudo** access on the server

Who does what?
- **IT / DevOps:** Steps D, F, G (once).
- **Developer:** Steps B, C + daily work.
- **Approver:** clicks **Approve** during Deploy.

---

## 5. Step A — Get the blueprint into your own repo

1. Open <https://github.com/Dedmoo/dotnet-cicd-template>
2. Green **Use this template → Create a new repository**.
3. Name it (e.g. `mycompany-app`) → **Create repository**.
4. You will see a `templates/` folder in the new repo. **Move everything inside it to the repo root:**
   - `.github/` must be **at the root**
   - `scripts/` must be **at the root**

Expected tree after moving:

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
└── src/            # your .NET code (Step B)
```

> **Why move?** GitHub Actions only runs the `.github/workflows/` folder at the **repo root**.
> While under `templates/.github/` it will not trigger.

**Check:** Does `.github/workflows/production-deploy.yml` exist at the repo root? Yes → continue.

### Files you must not edit

Do **not** edit these — project info is never written into the YML; it comes from the GitHub UI:

- `continuous-integration.yml`, `reusable-dotnet-build.yml`
- `production-deploy.yml`, `production-rollback.yml`
- `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`

---

## 6. Step B — Prepare your code (which code goes where)

The blueprint assumes a standard ASP.NET Core (.NET) app. You must satisfy **two small
requirements** in your code. Otherwise you use your normal project.

### 6.1 Where the code goes

Put your .NET project at the repo root. Example (your names may differ):

```
repo-root/
├── src/
│   └── Web/
│       ├── Web.csproj      # <-- you give this path in SERVICES
│       └── Program.cs
```

Note your `.csproj` path (e.g. `src/Web/Web.csproj`); you use it in Step C.

### 6.2 Requirement 1 — the app must bind to the given address (do not hard-code the URL)

On the server the app listens on a **Unix socket**. systemd starts it like this:

```
dotnet <path>/Web.dll --urls http://unix:/run/cicd/<service>-<color>.sock
```

ASP.NET Core Kestrel applies `--urls` automatically. **What you must do:** do **not** hard-code the
address in Program.cs. So none of this should exist:

```csharp
// WRONG — overrides --urls, the socket won't bind:
builder.WebHost.UseUrls("http://localhost:5000");
```

`launchSettings.json` is dev-only and ignored in production — that's fine. In short: remove any
URL-setting code and `--urls` just works.

### 6.3 Requirement 2 — a "health" endpoint must return 200

Deploy detects the new version is up by hitting the `health_url` path **over the socket** and
expecting **HTTP 200**. Your app must return 200 at that path.

Simplest way — one line in Program.cs (ASP.NET Core 6+ minimal API):

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// Health endpoint: deploy expects 200 here.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

// ... your other routes ...
app.Run();
```

Alternative: if your home page (`/`) already returns 200, you may set the `health_url` path to `/`.
But a dedicated `/health` is **recommended** (you can add dependency checks to it).

> `verify-health.sh` (manual test) tries `/health` body containing `"status":"ok"`, then HTTP 200,
> then `/` 200, in order. The automatic check inside deploy looks for **HTTP 200** directly.

### 6.4 (Optional) Environment variables / connection strings

Do not put secrets (DB connection, API key) in code. Put them in the GitHub `APP_ENV` **secret** as
`KEY=VALUE` lines (Step E). Deploy writes them as a `.env` file into each service folder and systemd
passes them to the app as environment variables.

ASP.NET Core reads nested config with double underscores. Example:

```
ConnectionStrings__Default=Server=...;Database=...;User Id=...;Password=...
MyApi__Key=sk-...
```

In code you access them normally, e.g. `builder.Configuration.GetConnectionString("Default")`.

---

## 7. Step C — Write the SERVICES line

`SERVICES` is the heart of the system. **Each line defines one service** with **five fields**
separated by `|`:

```
name|csproj|deploy_dir|service_name|health_url
```

| Field | Example | Meaning |
|---|---|---|
| `name` | `web` | Short name (artifact folder + label) |
| `csproj` | `src/Web/Web.csproj` | Path (in the repo) to the project to build |
| `deploy_dir` | `/opt/myapp-web` | Install directory on the server (base path) |
| `service_name` | `myapp-web` | systemd service name |
| `health_url` | `http://SERVER_IP:5001/health` | nginx **public port** + **health path** |

`health_url` is special — its three parts do:

- **PORT** (`5001`): the port nginx exposes. `setup-host.sh` assigns this to nginx.
- **PATH** (`/health`): the path used for the health check.
- **IP**: written for manual testing; **the pipeline checks over the socket and ignores the IP.**

### Single-service example

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://203.0.113.10:5001/health
```

### Two-service example (add a second line with Enter in the Variable box)

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://203.0.113.10:5001/health
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://203.0.113.10:5002/health
```

### Field rules (the script validates them)

- `deploy_dir`: only `letters, digits, / _ . @ -`.
- `service_name`: only `letters, digits, _ . @ -`.
- Invalid character → the pipeline errors before it starts (guards against command injection).

### What this line creates on the server (for understanding)

With `deploy_dir=/opt/myapp-web`, `service_name=myapp-web`, `setup-host.sh` creates:

- Folders: `/opt/myapp-web-blue` and `/opt/myapp-web-green`
- systemd units: `myapp-web-blue.service`, `myapp-web-green.service`
- Sockets: `/run/cicd/myapp-web-blue.sock`, `/run/cicd/myapp-web-green.sock`
- A low-privilege system user: `cicd-myapp-web` (the app runs as this, **not root**)
- nginx: listens on `5001`, routes to the active color
- Active-color state file: `/etc/nginx/cicd/myapp-web.active`

---

## 8. Step D — Prepare the server (remote)

> **In the local model** skip this section; the server = the runner machine. You only run
> `setup-host.sh` on that machine in Step G.

The following are done on the **target Linux server**, **once**, as root/sudo.

### D.1 — Generate an SSH key (on your computer)

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
```

Two files are created:
- `deploy_key` → **secret**. It becomes the GitHub Secret `SSH_PRIVATE_KEY`.
- `deploy_key.pub` → **public**. We put it on the server.

View `deploy_key` (you will copy the whole thing later):

```bash
cat deploy_key            # Linux / Mac / WSL
Get-Content deploy_key    # Windows PowerShell
```

It must start with `-----BEGIN OPENSSH PRIVATE KEY-----` and end with
`-----END OPENSSH PRIVATE KEY-----`. Copy all of it (including BEGIN/END).

### D.2 — `deploy` user + public key on the server

Log in: `ssh root@SERVER_IP`

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

On your computer copy the `cat deploy_key.pub` output (single line); on the server replace
`PASTE_HERE`:

```bash
echo "PASTE_HERE" | sudo tee /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### D.3 — Passwordless sudo (`NOPASSWD: ALL`) — required

The pipeline runs each server step via `sudo bash -c "..."`, so the `deploy` user needs full sudo.
Missing it breaks deploy with `sudo: a password is required`.

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
sudo -u deploy sudo -n true && echo "sudo OK"
```

Do not continue without seeing `sudo OK`.

> **Security note:** this is a broad privilege. Create the `deploy` user **only for this deployment
> server**, do not reuse it elsewhere. The app itself does **not run as root** (see Section 15).

### D.4 — Required packages

```bash
sudo apt-get update
sudo apt-get install -y rsync curl nginx
# Also the .NET runtime/SDK your project targets (e.g. .NET 8) must be installed
```

> If `nginx` is missing, `setup-host.sh` installs it automatically; having it pre-installed is fine.
> Firewall: the SSH port (22) and the health ports in `SERVICES` must be reachable by the runner.

### D.5 — Capture host identity (`SSH_KNOWN_HOSTS`) — required

**On your computer** (after leaving the server):

```bash
ssh-keyscan -p 22 SERVER_IP
```

Copy **all lines**; you paste them as a Variable in Step E.

> `SSH_KNOWN_HOSTS` is **required.** Without it the pipeline refuses to run (man-in-the-middle
> protection). The old "auto-accept" behavior was removed for security.

---

## 9. Step E — GitHub settings (Variables / Secrets / Environment)

In the repo, top menu **Settings**.

### E.1 — Variables (visible settings)

**Settings → Secrets and variables → Actions → Variables → New repository variable**

**For every model:**

| Name | Value |
|---|---|
| `SERVICES` | the line(s) from Step C |

**For remote also:**

| Name | Value |
|---|---|
| `DEPLOY_TARGET` | `remote` |
| `SSH_HOST` | server IP/hostname (e.g. `203.0.113.10`) |
| `SSH_USER` | `deploy` |
| `SSH_PORT` | `22` (if different, use it) |
| `SSH_KNOWN_HOSTS` | full `ssh-keyscan` output from Step D.5 |
| `RUNNER_LABEL` | `ubuntu-latest` |
| `ARTIFACT_NAME` | (optional) default `app-publish` |

**For local also:**

| Name | Value |
|---|---|
| `DEPLOY_TARGET` | `local` (or empty; local is the default) |
| `RUNNER_LABEL` | `self-hosted` (your runner label) |

### E.2 — Secrets (hidden settings)

**Settings → Secrets and variables → Actions → Secrets → New repository secret**

| Name | When | Value |
|---|---|---|
| `SSH_PRIVATE_KEY` | remote required | the **entire** `deploy_key` file (including BEGIN…END) |
| `APP_ENV` | optional | `KEY=VALUE` lines (connection string etc.) |

> Never put the private key in Variables; Secrets only.

### E.3 — `production` Environment (approval gate) — required

**Settings → Environments → New environment** → name it **exactly** `production`

| Setting | Value | Why |
|---|---|---|
| **Required reviewers** | At least 1 person | No unapproved production deploy |
| **Prevent self-review** | On | The trigger can't approve their own deploy |
| **Deployment branches** | `main` only | No production from feature branches |
| **Wait timer** | (optional) 5–15 min | Cancel window after approval |

Deploy and Rollback both bind to this environment.

---

## 10. Step F — Runner (who runs the commands?)

**remote (RUNNER_LABEL=ubuntu-latest):** No extra setup. GitHub's hosted `ubuntu-latest` runner
does the work; it connects to your server via SSH. This is the easiest path.

**local (RUNNER_LABEL=self-hosted):** You must install a **self-hosted runner** on the machine that
runs the jobs:

1. Repo → **Settings → Actions → Runners → New self-hosted runner → Linux**.
2. Run the shown commands on that machine (download → `./config.sh --url ... --token ...`).
3. Run it as a service:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status     # should be active (running)
```

4. In **Settings → Actions → Runners** it should show green/`Idle`.

> CI assumes `dotnet` is installed on the runner (it does not run `setup-dotnet`).
> `ubuntu-latest` ships a recent .NET SDK; if you need a specific version, add a `global.json`
> to the repo. On a self-hosted runner verify with `dotnet --version`.

---

## 11. Step G — One-time host setup script

This script creates the **systemd units and nginx configuration** on the server. Run it **once**.

### remote

On your computer, at the repo root (with `scripts/` and `deploy_key` present):

```bash
SSH_HOST=SERVER_IP \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_KNOWN_HOSTS="$(ssh-keyscan -p 22 SERVER_IP)" \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SERVER_IP:5001/health" \
bash scripts/setup-remote-host.sh
```

On Windows without `bash`, use **WSL** or **Git Bash**.

### local

On the server (runner) itself:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001/health" \
     bash scripts/setup-host.sh
```

### What the script does

For each service:
1. Creates a low-privilege system user (`cicd-<service>`).
2. Installs two systemd units (`<service>-blue`, `<service>-green`) — listen on a Unix socket,
   run as `User=cicd-<service>` (**not root**) with systemd hardening.
3. Writes the nginx upstream include + public-port server block (default color: blue).
4. Initializes the active-color state file (`/etc/nginx/cicd/<service>.active`) to `blue`.

When done, the app folders may be **empty** — that's normal; the first deploy fills them. Services
come up after the first successful deploy.

---

## 12. Step H — First CI and first Deploy

### H.1 — CI (automatic)

Push a small change to `main`. Wait for **Actions → Continuous Integration** to go **green**. CI
runs automatically; on push to `main` it also produces an **artifact**.

If red: click the red step and read the log (usually a wrong `SERVICES` path or the runner's .NET
version).

### H.2 — Deploy (manual + approved)

Deploy is **not automatic**; it is a deliberate action.

1. **Actions → Production Deploy → Run workflow**.
2. Write a **description** (required), e.g. `first live test`.
3. **Source:**
   - `ci_artifact` (default/recommended) — uses the artifact CI produced. **Requirement:** there
     must be a successful CI run for that commit (otherwise deploy stops on a commit mismatch).
   - `build_from_source` — builds at deploy time. Use this once if there is no CI artifact yet.
4. **Run workflow**.
5. First the **prepare** step goes green and writes an **approval summary** (who, description,
   commit, SHA).
6. The approver reads the summary → **Review deployments → Approve**.
7. Deploy runs: writes to the idle color → health check → if it passes, switches nginx.

On success your app answers at the `health_url`.

---

## 13. Daily workflow (the part shown in the video)

After setup, on each change:

1. Change the code (in your editor).
2. `git add .`
3. `git commit -m "what changed"`
4. `git push origin main`
5. Wait for **Actions → Continuous Integration** to be green.
6. **Actions → Production Deploy → Run workflow** → description → `ci_artifact` → Run.
7. Approver clicks **Approve**.
8. Check the site (F5).

The video only shows this loop.

---

## 14. Rollback

**Actions → Production Rollback → Run workflow** with two modes:

| Mode | What it does |
|---|---|
| `previous_folder` | Switches nginx to the **other color** (previous version) instantly — no rebuild, zero downtime |
| `specific_commit` | Builds/publishes the given commit to the idle color, switches on health pass (enter `commit_sha`) |

`previous_folder` is the fastest: the old color is already up, so traffic returns instantly.
Rollback is also subject to `production` approval.

Before switching, rollback **automatically validates** (inside the pipeline):
- Target color directory exists **and** contains the published DLL (empty folders are rejected)
- Target color socket passes health check (unhealthy release never receives traffic)
- If nginx reload or state write fails, upstream is automatically reverted to the previous color

> **Important:** `previous_folder` works only when the **other color was previously deployed successfully**.
> Right after the very first deploy (only one color filled), the rollback target is missing and the
> operation aborts without changes — this is expected. After a second deploy both colors are
> populated and instant rollback becomes available.

---

## 15. Security model (what you should know)

This system is hardened; what you should know:

- **The app does not run as root.** Each service runs as its own low-privilege `cicd-<service>`
  user, with systemd hardening (`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp` …).
  A vulnerability in the app does not directly become root.
- **`SSH_KNOWN_HOSTS` is required.** No remote deploy without verifying the server identity up front.
- **Provenance.** When deploying with `ci_artifact`, the CI commit that produced the artifact must
  equal the deployed commit; otherwise deploy stops.
- **Approval gate.** Production deploy/rollback require `production` environment approval; with
  `prevent self-review` the trigger cannot approve their own run.
- **Least privilege.** Workflows run with only the needed read permissions; actions are pinned to
  full commit SHAs.
- **`.env` is readable only by the service user** (`0640 cicd-<service>:cicd`).

**Known trade-off:** the `deploy` user has broad sudo on the server (because the pipeline uses
`sudo bash -c`). Therefore dedicate the `deploy` user to deployment only and keep the SSH key
(Secret) tight. Details: [`security-review.tr.md`](./security-review.tr.md).

---

## 16. Troubleshooting

| On screen | Likely cause / fix |
|---|---|
| `Permission denied (publickey)` | `deploy_key.pub` not in the server's `authorized_keys`, or wrong user |
| `sudo: a password is required` | Step D.3 sudoers not done (no `sudo OK`) |
| `Host key verification failed` / `SSH_KNOWN_HOSTS not set` | `SSH_KNOWN_HOSTS` empty/wrong → do Step D.5 |
| `invalid format` / libcrypto | Private key pasted incompletely into the Secret (BEGIN/END must be included) |
| Deploy: "CI artifact commit != deploy commit" | No green CI for that commit → push + wait for CI, or pick `build_from_source` |
| Health fail — live not affected | App does not return 200 on the socket: is `/health` present? Is the URL hard-coded? (Sections 6.2–6.3) |
| CI red | Is the runner online? Are `SERVICES` paths correct? Is the runner's `dotnet` version OK? |
| Deploy waiting for approval | The approver must sign in with a **different** account and click Approve (if self-review is off) |
| nginx health port not responding | Did `setup-host.sh`/`setup-remote-host.sh` run? Is the firewall port open? |

Quick checks on the server (via SSH):

```bash
sudo systemctl status myapp-web-blue myapp-web-green   # service status
sudo nginx -t                                           # nginx config test
cat /etc/nginx/cicd/myapp-web.active                    # currently active color
sudo journalctl -u myapp-web-blue -n 50 --no-pager      # app log
```

---

## 17. Setup complete — checklist

**Common:**
- [ ] Template → new repo; `templates/` contents at the **root** (`.github/`, `scripts/`)
- [ ] Code: URL not hard-coded + `/health` (or `/`) returns 200
- [ ] `SERVICES` in the correct format (5 fields, separated by `|`)
- [ ] `production` environment: required reviewers + prevent self-review + `main` only
- [ ] **Continuous Integration** green at least once
- [ ] **Production Deploy** triggered with a description and approved

**remote extra:**
- [ ] `deploy` user + `authorized_keys` on the server
- [ ] `sudo OK` obtained (`NOPASSWD: ALL`)
- [ ] `rsync`, `curl`, `nginx` (+ .NET) installed on the server
- [ ] Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`, `SSH_KNOWN_HOSTS`
- [ ] Secret: `SSH_PRIVATE_KEY` (full text, BEGIN/END)
- [ ] `setup-remote-host.sh` ran once (nginx + systemd units created)

**local extra:**
- [ ] Self-hosted runner online (green)
- [ ] `DEPLOY_TARGET=local`, `RUNNER_LABEL=self-hosted`
- [ ] `setup-host.sh` ran once

All checked → setup is **done**. From now on: write code → push → CI green → Production Deploy → approve.

---

## Helpful links

- Blueprint repo: <https://github.com/Dedmoo/dotnet-cicd-template>
- Click-by-click guide: [`beginner-walkthrough.en.md`](./beginner-walkthrough.en.md)
- Reference tables: [`company-setup.en.md`](./company-setup.en.md)
- Deep playbook: [`dotnet-cicd-template.en.md`](./dotnet-cicd-template.en.md)
- Turkish version: [`kendi-projene-entegrasyon.tr.md`](./kendi-projene-entegrasyon.tr.md)
