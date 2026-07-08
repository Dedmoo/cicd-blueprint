# For Complete Beginners — Click-by-Click Setup

This guide is for people who have heard of **CI/CD, SSH, or GitHub Actions** but have never set them up.

- You do not need to “learn the theory” first.
- Do not open or edit YML files.
- Follow the numbered steps in order.
- When something fails, read the red error text — it usually names what you forgot.

Shorter technical reference (variable tables, etc.): [`company-setup.en.md`](./company-setup.en.md)  
Türkçe: [`beginner-walkthrough.tr.md`](./beginner-walkthrough.tr.md)

---

## What does this system do? (30 seconds)

The goal is: **ship a new version to live.** People using the site / app pick up the update as they browse or refresh (e.g. F5). There is no “announce downtime and make everyone manually close / reset the app” ritual.

In short:

1. When code is pushed to GitHub it is **built and tested automatically**.
2. An authorized person **approves** going live.
3. After approval the new version is **published to the remote server** — users do not run a separate “reset / restart ceremony”; their next requests (e.g. refresh) get the updated version.
4. If the new version does not come up healthy, the system **tries to return to the previous version**.

Your job: fill in the settings once. After that: write code → get approval → live updates.

> Technical note (for the curious): Under the hood the server process is refreshed briefly. We are not selling “restart” as the product feature. The product goal is quiet, approved updates for users.

---

## Two paths — pick one

| Option | Meaning | Who |
|---|---|---|
| **A — Same machine** | The machine that runs jobs is also the server | Self-hosted runner setups |
| **B — Remote server** | The app lives on a separate Linux server | Most companies / live trials — **this guide is B** |

For A, see the “Local” section in [`company-setup.en.md`](./company-setup.en.md). Below is **B (remote)** only.

---

## What you need before starting

- [ ] A **GitHub account**
- [ ] Permission to copy the template into your account
- [ ] A **Linux server** (IP/hostname, reachable over SSH)
- [ ] **Admin (root/sudo)** access on that server
- [ ] A terminal on your PC (Windows: PowerShell or WSL; Mac/Linux: Terminal)
- [ ] Your .NET application code (or a sample app)

Words you will see:

| Word | Plain meaning |
|---|---|
| **Repo** | Your project folder on GitHub |
| **Variable** | A setting visible to repo maintainers |
| **Secret** | A hidden setting (keys/passwords); not shown in logs |
| **Environment** | The “ask for approval before production” box |
| **Runner** | The computer GitHub uses to run commands for you |
| **SSH** | Remote login with a key (no password each time) |
| **Deploy** | Going live / publishing the new version to users |

---

## Section 0 — Create a key (on your computer)

This key lets GitHub prove to the server “I am allowed.” No password prompt per deploy.

1. Open a terminal.
2. Paste and press Enter:

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
```

3. Two files appear in that folder:
   - `deploy_key` → **secret**. You will paste it into a GitHub Secret.
   - `deploy_key.pub` → **public**. You will put it on the server.

4. View the private key:

```bash
# Linux / Mac / WSL
cat deploy_key

# Windows PowerShell
Get-Content deploy_key
```

You should see text starting with `-----BEGIN OPENSSH PRIVATE KEY-----`. Keep it temporarily (Notepad). Delete from Notepad when finished.

---

## Section 1 — Create the GitHub project

1. Open https://github.com/Dedmoo/dotnet-cicd-template  
2. Green **Use this template** → **Create a new repository**  
3. Name it (e.g. `mycompany-app`) → **Create**  
4. After it opens, move everything inside `templates/` to the **repo root**:
   - `.github` must be at the root  
   - `scripts` must be at the root  
5. Put your .NET code in the same repo root (`src/...`).  
6. Push to the `main` branch.

Check: Can you see `.github/workflows/production-deploy.yml` at the repo root? Yes → continue.

---

## Section 2 — Prepare the server (Linux, once)

SSH in as admin (replace with your IP):

```bash
ssh root@SERVER_IP
```

or with your sudo-capable user.

### 2.1 Create the user

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

### 2.2 Put the public key on the server

On your PC, copy `deploy_key.pub`:

```bash
cat deploy_key.pub
```

On the server (replace `PASTE` with that one line):

```bash
echo "PASTE" | sudo tee /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### 2.3 Passwordless admin rights (critical)

Without this, live deploy will go **red**:

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
sudo -u deploy sudo -n true && echo "sudo OK"
```

You must see `sudo OK`. If not, stop — do not continue.

### 2.4 Required packages

```bash
sudo apt-get update
sudo apt-get install -y rsync curl
```

Also install the **.NET** version your app needs (whatever your company uses — e.g. .NET 8).

### 2.5 Capture host identity (`SSH_KNOWN_HOSTS`)

**On your PC** (after leaving the server session):

```bash
ssh-keyscan -p 22 SERVER_IP
```

Copy **all** output lines. You will paste them into a GitHub Variable next.

---

## Section 3 — GitHub settings (click by click)

In the repo: top menu **Settings**.

### 3.1 Variables

Path: **Settings → Secrets and variables → Actions → Variables** → **New repository variable**

Add these **one by one**:

| Name | Value — replace with your real data |
|---|---|
| `DEPLOY_TARGET` | `remote` |
| `SSH_HOST` | Server IP or domain (e.g. `203.0.113.10`) |
| `SSH_USER` | `deploy` |
| `SSH_PORT` | `22` (or your SSH port) |
| `RUNNER_LABEL` | `ubuntu-latest` |
| `SSH_KNOWN_HOSTS` | Full `ssh-keyscan` output from Section 2.5 |
| `SERVICES` | Adapt the one-liner below to your paths |

Example `SERVICES` (one app):

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SERVER_IP:5001
```

Meaning (you do not need to memorize this):

- `web` = short name  
- `src/Web/Web.csproj` = project file to build (use your real path)  
- `/opt/myapp-web` = folder on the server  
- `myapp-web` = service name  
- `http://SERVER_IP:5001` = health check URL  

**Do not** use `http://127.0.0.1:5001` for remote. It will fail. Use the server IP.

For multiple services: press Enter in the Variable box for another line.

### 3.2 Secrets

Path: **Settings → Secrets and variables → Actions → Secrets** → **New repository secret**

| Name | Value |
|---|---|
| `SSH_PRIVATE_KEY` | The **entire** text of `deploy_key` from Section 0 (`BEGIN` … `END` included) |

Optional:

| Name | Value |
|---|---|
| `APP_ENV` | App env lines, e.g. `ConnectionStrings__Default=...` |

### 3.3 Production approval box

Path: **Settings → Environments → New environment**

1. Name it **exactly**: `production`  
2. **Configure environment**  
3. **Required reviewers** → pick at least one person  
4. Enable **Prevent self-review** if available  
5. Deployment branches → **Selected branches** → only `main`  
6. Save  

Without this, Production Deploy may behave unexpectedly around approvals.

---

## Section 4 — One-time host setup script

On your PC, from the repo root where `scripts/` exists (and `deploy_key` is nearby):

```bash
SSH_HOST=SERVER_IP \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SERVER_IP:5001" \
bash scripts/setup-remote-host.sh
```

On Windows PowerShell without `bash`, use WSL or Git Bash.

If it finishes with no error, systemd units are on the server. The app folder may still be empty until the first deploy.

---

## Section 5 — First automatic build (CI)

1. Push any small change to `main` (or wait if you already pushed).  
2. Open the repo → **Actions**.  
3. Wait for **Continuous Integration** to show a green check.

If red: open the failed step and read the log (often a wrong `SERVICES` path or missing .NET).

---

## Section 6 — Go live (Deploy)

1. **Actions** → left sidebar **Production Deploy**  
2. **Run workflow**  
3. Type a description (required), e.g. `first live trial`  
4. Source: leave **`ci_artifact`** (if there is no artifact yet, pick `build_from_source` once)  
5. **Run workflow**  

Then:

1. The run opens → **prepare** turns green first (writes a summary).  
2. The reviewer checks Summary / the approval screen → **Approve**.  
3. Deploy finishes → on failure it may auto-rollback.

Success: your app answers at the `health_url`.

---

## If something breaks (short dictionary)

| What you see | Likely missing piece |
|---|---|
| `Permission denied (publickey)` | `.pub` not on server or wrong user |
| `sudo: a password is required` | Section 2.3 sudoers not done |
| `Host key verification failed` | Empty/wrong `SSH_KNOWN_HOSTS` |
| `invalid format` / libcrypto | Incomplete key pasted into the Secret |
| Health fail but SSH works | `127.0.0.1` in `SERVICES` or firewall closed |
| Artifact not found | CI must be green first — or use `build_from_source` once |

Longer table: [`README.md`](../README.md) troubleshooting section.

---

## Done checklist

- [ ] `deploy_key` / `.pub` created  
- [ ] Server has `deploy` + authorized_keys  
- [ ] Saw `sudo OK`  
- [ ] GitHub Variables set  
- [ ] Secret `SSH_PRIVATE_KEY` set  
- [ ] Environment `production` + reviewer  
- [ ] `setup-remote-host.sh` ran  
- [ ] Continuous Integration green  
- [ ] Production Deploy approved and successful  

All checked → **setup is finished**. Daily work: code → push → CI green → Production Deploy → approve.
