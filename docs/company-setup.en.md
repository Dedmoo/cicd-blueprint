# Company Setup Guide — dotnet-cicd-template

**EN:** This guide lists **all configuration steps in one place** to adapt `dotnet-cicd-template` to your project. You do not touch any YML file; all project values are entered via the GitHub UI as Variables and Secrets.

**TR:** Bu rehber, `dotnet-cicd-template`'i kendi projenize uyarlamak için gereken **tüm yapılandırma adımlarını tek bir yerde** listeler. Hiçbir YML dosyasına dokunmazsınız; tüm proje bilgileri GitHub arayüzü üzerinden Variables ve Secrets olarak girilir.

---

## Step 1 — Create the repo

1. Go to [github.com/Dedmoo/dotnet-cicd-template](https://github.com/Dedmoo/dotnet-cicd-template).
2. Click **Use this template → Create a new repository**.
3. In the new repo, move the contents of the `templates/` folder to the **root** (`.github/` and `scripts/` must be at the root).

> Expected tree:
> ```
> repo-root/
> ├── .github/
> │   ├── actions/build-test/action.yml
> │   └── workflows/
> │       ├── continuous-integration.yml
> │       ├── reusable-dotnet-build.yml
> │       ├── production-deploy.yml
> │       └── production-rollback.yml
> └── scripts/
>     ├── pipeline.sh
>     ├── ssh-remote.sh
>     ├── verify-health.sh
>     ├── setup-host.sh
>     └── setup-remote-host.sh
> ```

---

## Step 2 — Repository Variables

**GitHub:** Settings → Secrets and variables → Actions → **Variables** tab → **New repository variable**

| Variable | Required | Example value | Description |
|---|---|---|---|
| `SERVICES` | **Yes** | `web\|src/Web/Web.csproj\|/opt/myapp-web\|myapp-web\|http://127.0.0.1:5001` | Service list; each line `name\|csproj\|deploy_dir\|service_name\|health_url`. For multiple services, each on its own line. |
| `DEPLOY_TARGET` | No | `local` or `remote` | Default: `local`. Use `local` when the runner is the target host; use `remote` to deploy to a separate server via SSH. |
| `RUNNER_LABEL` | No | `self-hosted` or `ubuntu-latest` | Runner label. `self-hosted` for local mode; usually `ubuntu-latest` for remote mode. |
| `ARTIFACT_NAME` | No | `app-publish` | CI artifact name. Default is `app-publish`; no change needed for a single-service setup. |
| `SSH_HOST` | Remote | `192.168.1.100` or `myserver.com` | IP or hostname of the target server. Required only when `DEPLOY_TARGET=remote`. |
| `SSH_USER` | Remote | `deploy` | SSH username. Required only when `DEPLOY_TARGET=remote`. |
| `SSH_PORT` | No | `22` | SSH port. Default is `22`. |
| `SSH_KNOWN_HOSTS` | Recommended | `myserver.com ssh-ed25519 AAAA...` | Host key line of the server. Paste the output of `ssh-keyscan -p 22 <SSH_HOST>` here. Without this value, `ssh-keyscan` runs on every pipeline step, which can cause connection issues on modern SSH servers. |

### Multi-line `SERVICES` example

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5002
```

Paste each service on a separate line in the GitHub Variables text field.

---

## Step 3 — Repository Secrets

**GitHub:** Settings → Secrets and variables → Actions → **Secrets** tab → **New repository secret**

| Secret | Required | What to paste |
|---|---|---|
| `SSH_PRIVATE_KEY` | Remote | A **passphrase-free** SSH private key in `ed25519` format. Paste the full text starting with `-----BEGIN OPENSSH PRIVATE KEY-----` and ending with `-----END OPENSSH PRIVATE KEY-----`. Ensure there are no missing lines or extra spaces. |
| `APP_ENV` | No | `KEY=VALUE` lines in `.env` format. Injected into each service as `.env` at deploy time. Example: `DATABASE_URL=postgresql://...` or `API_KEY=abc123`. |

### Generating an SSH key

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
# deploy_key      → paste into SSH_PRIVATE_KEY secret
# deploy_key.pub  → append to ~/.ssh/authorized_keys on the server
```

---

## Step 4 — `production` Environment

**GitHub:** Settings → **Environments** → **New environment** → name it `production` → **Configure**

| Setting | Value | Why |
|---|---|---|
| **Required reviewers** | Add at least 1 person | Prevents unapproved production deploys |
| **Prevent self-review** | Enabled | The person who triggers a deploy cannot approve their own deployment |
| **Deployment branches** | Select the `main` branch | Prevents accidentally deploying from a feature branch |
| **Wait timer** | 5–15 min (optional) | Provides a cancellation window after approval |

> Before approving, the reviewer should check the **prepare** job summary (description, commit message, SHA) on the Actions run page. "The reviewer must not approve without first reading the prepare summary."

---

## Step 5 — Host Setup (One-time)

### Local (`DEPLOY_TARGET=local`)

When the runner and the target host are the same machine, run **once** on that machine:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
     bash scripts/setup-host.sh
```

The script creates systemd service units, prepares the deploy directories, and writes an empty `.dll` placeholder.

### Remote (`DEPLOY_TARGET=remote`)

Setup is performed **via SSH** from the deploy runner to the target server:

```bash
SSH_HOST=192.168.1.100 \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
bash scripts/setup-remote-host.sh
```

**sudoers requirement on the server:** The deploy user needs passwordless `sudo` for the following commands:

```
deploy ALL=(ALL) NOPASSWD: /bin/systemctl, /bin/mkdir, /bin/cp, /bin/rm, /bin/chown
```

Write access to `/opt/...` directories must also be granted.

---

## Step 6 — First CI and Deploy

1. Push to the `main` branch → `continuous-integration.yml` triggers automatically → confirm it is green.
2. Actions → **Production Deploy** → **Run workflow** → enter a description, leave **source: `ci_artifact`** selected → **Run workflow**.
3. The reviewer checks the prepare summary and approves → deploy begins.

---

## Files you do not edit

The following files are managed by the template; **do not modify them:**

- `continuous-integration.yml`
- `reusable-dotnet-build.yml`
- `production-deploy.yml`
- `production-rollback.yml`
- `pipeline.sh`
- `ssh-remote.sh`
- `verify-health.sh`

All project values are read exclusively from **GitHub Variables / Secrets**.

---

## Quick checklist

- [ ] `SERVICES` variable defined and correctly formatted
- [ ] `DEPLOY_TARGET` set (`local` or `remote`)
- [ ] `RUNNER_LABEL` matches the runner label
- [ ] `production` environment created, required reviewers added
- [ ] (remote) `SSH_PRIVATE_KEY` secret pasted
- [ ] (remote) `SSH_KNOWN_HOSTS` variable filled in
- [ ] (remote) sudoers configured on the server
- [ ] Host setup script executed
- [ ] First CI run is green
