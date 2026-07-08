# CI/CD Pipeline Blueprint

**TR:** Projeden bağımsız, kopyala-yapıştır bir CI/CD boru hattı şablonu. Kendinden barındırmalı (self-hosted) bir GitHub Actions çalıştırıcısı üzerinde; otomatik derleme/test, onaya bağlı üretim dağıtımı, sağlık kontrolü ve hata durumunda otomatik geri alma sağlar. Herhangi bir .NET projesine tek bir `SERVICES` bloğu doldurularak dakikalar içinde uyarlanır.

**EN:** A project-agnostic, copy-paste CI/CD pipeline template. On a self-hosted GitHub Actions runner it provides automatic build/test, approval-gated production deployment, health checks and automatic rollback on failure. It adapts to any .NET project in minutes by filling in a single `SERVICES` block.

---

## İçindekiler / Table of Contents

- [Özellikler / Features](#özellikler--features)
- [Genel süreç akışı / Overall process flow](#genel-süreç-akışı--overall-process-flow)
- [1. Sürekli Entegrasyon (CI) / Continuous Integration](#1-sürekli-entegrasyon-ci--continuous-integration)
- [2. Yapı Çıktısı ve Build-Once/Deploy-Many / Artifacts](#2-yapı-çıktısı-ve-build-oncedeploy-many--artifacts)
- [3. Sürekli Dağıtım (Deploy) / Continuous Deployment](#3-sürekli-dağıtım-deploy--continuous-deployment)
- [4. Onay Mekanizması / Approval Gate](#4-onay-mekanizması--approval-gate)
- [5. Sağlık Kontrolü / Health Check](#5-sağlık-kontrolü--health-check)
- [6. Otomatik Geri Alma / Automatic Rollback](#6-otomatik-geri-alma--automatic-rollback)
- [7. Manuel Geri Alma / Manual Rollback](#7-manuel-geri-alma--manual-rollback)
- [8. Denetlenebilirlik / Auditability](#8-denetlenebilirlik--auditability)
- [9. Eşzamanlılık Koruması / Concurrency Guard](#9-eşzamanlılık-koruması--concurrency-guard)
- [Kod yazmazsınız — sadece bilgi girersiniz / No code — you only fill in values](#kod-yazmazsınız--sadece-bilgi-girirsiniz--no-code--you-only-fill-in-values)
- [Uzak sunucu deploy (SSH) / Remote server deploy (SSH)](#uzak-sunucu-deploy-ssh--remote-server-deploy-ssh)
- [Kurulum checklist / Setup checklist](#kurulum-checklist--setup-checklist)
- [Uçtan uca senaryolar / End-to-end scenarios](#uçtan-uca-senaryolar--end-to-end-scenarios)
- [Hızlı başlangıç / Quick start](#hızlı-başlangıç--quick-start)
- [Dosya yapısı / File structure](#dosya-yapısı--file-structure)
- [Dokümantasyon / Documentation](#dokümantasyon--documentation)

---

## Özellikler / Features

| Özellik / Feature | Açıklama / Description |
|---|---|
| **Otomatik CI** | `main`'e her push ve PR'de otomatik derleme + test / Auto build + test on every push/PR to `main` |
| **Yapı çıktısı (artifact)** | Testten geçen çıktı saklanır, deploy'da yeniden kullanılır / Tested output is stored and reused at deploy |
| **Build-once, deploy-many** | Test edilen ile canlıya çıkan birebir aynı / What is tested equals what ships |
| **Onaya bağlı deploy** | Üretim için manuel onay kapısı (`production` environment) / Manual approval gate for production |
| **Sağlık kontrolü** | Deploy sonrası her servisin ayakta olduğu doğrulanır / Post-deploy verification per service |
| **Otomatik geri alma** | Sağlık başarısızsa önceki sürüme otomatik dönüş / Auto-revert on failed health check |
| **Manuel geri alma** | Önceki klasör veya belirli commit ile / Via previous folder or a specific commit |
| **Denetlenebilirlik** | Her dağıtımda kim/ne zaman/hangi commit kaydı / Who/when/which commit recorded per deploy |
| **Çok servis desteği** | Tek `SERVICES` bloğuyla N servis / N services via one `SERVICES` block |
| **Atomik güncelleme** | `rsync --delete` ile tutarlı dosya durumu / Consistent files via `rsync --delete` |
| **Eşzamanlılık koruması** | Çakışan deploy/rollback engellenir / Prevents clashing deploy/rollback |
| **Köken doğrulama (provenance)** | `ci_artifact`'ın commit'i, deploy commit'i ile birebir eşleşmezse deploy durur / Deploy stops if the artifact's commit does not match the deploy commit |
| **En az yetki (least privilege)** | İş akışları yalnızca gereken okuma yetkileriyle çalışır / Workflows run with only the minimal read permissions |

---

## Genel süreç akışı / Overall process flow

**TR:** Aşağıdaki şema, bir kod değişikliğinin doğrulanmasından canlıya çıkmasına ve gerekirse geri alınmasına kadar tüm yolu gösterir. CI otomatiktir; Deploy ve Rollback bilinçli, onaylı eylemlerdir.

**EN:** The diagram below shows the full path of a code change from validation to going live and, if needed, being rolled back. CI is automatic; Deploy and Rollback are deliberate, approved actions.

```mermaid
flowchart TB
    DEV["Geliştirici push / PR<br/>Developer push / PR"] --> CI

    subgraph CI["1. CI (otomatik / automatic)"]
        direction LR
        C1["verify .NET"] --> C2["cache"] --> C3["restore"] --> C4["build"] --> C5["test"] --> C6["artifact (push'ta / on push)"]
    end

    CI -->|yeşil / green| READY["Deploy'a hazır<br/>Ready to deploy"]
    READY --> TRIG["Deploy elle tetiklenir<br/>Deploy triggered manually"]
    TRIG --> APPR{"production onayı<br/>production approval"}
    APPR -->|reddedildi / rejected| STOP["Durur / Stops"]
    APPR -->|onaylandı / approved| DEP

    subgraph DEP["3. Deploy"]
        direction TB
        D1["build/test VEYA CI artifact"] --> D2["backup -> *.previous"] --> D3["publish (rsync --delete)"] --> D4["write .deploy-info"] --> D5["restart (systemd)"] --> D6["health check"]
    end

    D6 --> HC{"sağlıklı mı?<br/>healthy?"}
    HC -->|Evet / Yes| LIVE["Canlı / Live"]
    HC -->|Hayır / No| RB["Otomatik rollback + iş başarısız<br/>Auto rollback + job fails"]
    RB --> PREV["Önceki sürüm canlı<br/>Previous version live"]
```

---

## 1. Sürekli Entegrasyon (CI) / Continuous Integration

**TR:** CI, `main` dalına yapılan her `push` ve açılan her `pull_request` ile **otomatik** tetiklenir. Amacı, hatalı kodun daha ilk anda yakalanmasıdır. Sırasıyla şu adımlar koşar:

**EN:** CI is triggered **automatically** on every `push` to `main` and every `pull_request`. Its purpose is to catch faulty code as early as possible. It runs the following steps in order:

| # | Adım / Step | Ne yapar / What it does |
|---|---|---|
| 1 | .NET sürüm doğrulama / version check | Runner'da .NET 8+ SDK/runtime var mı / Ensures .NET 8+ on runner |
| 2 | NuGet cache | Paketleri önbelleğe alır, tekrarları hızlandırır / Caches packages, speeds up repeats |
| 3 | restore | Bağımlılıkları yükler / Restores dependencies |
| 4 | build (Release) | Çözümü derler / Builds the solution |
| 5 | test | Tüm test paketini çalıştırır / Runs the full test suite |
| 6 | artifact | Sadece `main`'e push'ta yapı çıktısı üretir / Produces build output only on push to `main` |

**TR:** Derleme/test mantığı yeniden kullanılabilir bir **bileşik eylem** (`build-test/action.yml`) içinde toplanmıştır; hem CI, hem "kaynaktan deploy", hem de commit tabanlı rollback aynı eylemi kullanır (kod tekrarı yok). CI'nin kendisi de `workflow_call` ile çağrılabilen **yeniden kullanılabilir bir iş akışıdır**.

**EN:** The build/test logic is gathered into a reusable **composite action** (`build-test/action.yml`); CI, "deploy from source" and commit-based rollback all use the same action (no duplication). CI itself is a **reusable workflow** callable via `workflow_call`.

---

## 2. Yapı Çıktısı ve Build-Once/Deploy-Many / Artifacts

**TR:** `main`'e push olduğunda, her servis yayımlanır (`dotnet publish`) ve hepsi **tek birleşik artifact** (`app-publish`) olarak 30 gün saklanır. Bu, boru hattının en önemli ilkelerinden birini mümkün kılar: **build-once, deploy-many.** Yani test edilen yapı ile canlıya çıkan yapı **birebir aynıdır**; deploy anında yeniden derlemeye gerek kalmadan bu doğrulanmış çıktı kullanılabilir (`ci_artifact` kaynağı).

**EN:** On push to `main`, each service is published (`dotnet publish`) and stored for 30 days as a **single combined artifact** (`app-publish`). This enables one of the pipeline's key principles: **build-once, deploy-many.** The tested build and the shipped build are **byte-for-byte identical**; at deploy time this validated output can be used without rebuilding (the `ci_artifact` source).

**TR — Köken doğrulama (provenance):** `ci_artifact` ile deploy edilirken, artifact'ı üreten CI çalışmasının commit'i (`headSha`) ile o an deploy edilen commit (`github.sha`) karşılaştırılır. Eşleşmezse deploy **durur**. Böylece "test edilen commit ile canlıya çıkan commit farklı" durumu engellenir; bu, `ci_artifact`'ı varsayılan ve güvenli kaynak yapan garantidir.

**EN — Provenance:** When deploying with `ci_artifact`, the commit of the CI run that produced the artifact (`headSha`) is compared with the commit being deployed (`github.sha`). If they differ, the deploy **stops**. This prevents "the tested commit differs from the shipped commit" and is the guarantee that makes `ci_artifact` the default, safe source.

---

## 3. Sürekli Dağıtım (Deploy) / Continuous Deployment

**TR:** Deploy **otomatik değildir** — bilinçli, elle tetiklenen (`workflow_dispatch`) bir eylemdir. İki girdi alır:

**EN:** Deploy is **not automatic** — it is a deliberate, manually triggered (`workflow_dispatch`) action. It takes two inputs:

- `description` — **TR:** Bu dağıtımda neyin değiştiğinin açıklaması (zorunlu). / **EN:** A description of what changed in this deploy (required).
- `source` — **TR:** Kaynak: `ci_artifact` (**varsayılan/önerilen** — son başarılı CI çıktısını kullanır, commit köken doğrulaması yapılır) veya `build_from_source` (deploy anında kaynaktan derler; ör. henüz CI artifact'ı olmayan ilk kurulum veya acil/hata ayıklama durumları). / **EN:** Source: `ci_artifact` (**default/recommended** — uses the latest successful CI output with commit provenance check) or `build_from_source` (rebuild at deploy; e.g. first setup with no CI artifact yet, or emergency/debug cases).

**TR:** Onay verildikten sonra dağıtım şu adımlarla ilerler:

**EN:** After approval, the deployment proceeds through these steps:

| # | Adım / Step | Ne yapar / What it does |
|---|---|---|
| 1 | Kaynak hazırlığı / source prep | `ci_artifact` → artifact indir + commit köken doğrulaması / download artifact + commit provenance check · `build_from_source` → derle+test / build+test |
| 2 | **backup** | Mevcut `/opt/...` dizinlerini `*.previous`'a kopyalar / Copies current dirs to `*.previous` |
| 3 | **publish** | Yeni sürümü `rsync -a --delete` ile hedefe yansıtır (atomik) / Mirrors new release atomically |
| 4 | **write-info** | `.deploy-info` dosyasına künye yazar / Writes deployment record |
| 5 | **restart** | Servisleri `systemctl restart` ile yeniler / Restarts services |
| 6 | **health** | Her servisin ayakta olduğunu doğrular / Verifies each service is up |
| 7 | başarısızsa / on fail | Otomatik rollback + işi başarısız say / Auto rollback + fail the job |

**TR:** Tüm bu ağır iş, tek bir `pipeline.sh` scriptinin alt komutlarıyla yapılır: `backup`, `publish-source`, `deploy-artifacts`, `write-info`, `restart`, `health`, `rollback`. Hepsi `SERVICES`'i okuyup tüm servisler üzerinde döner.

**EN:** All this heavy lifting is done by subcommands of a single `pipeline.sh` script: `backup`, `publish-source`, `deploy-artifacts`, `write-info`, `restart`, `health`, `rollback`. Each reads `SERVICES` and iterates over all services.

---

## 4. Onay Mekanizması / Approval Gate

**TR:** Üretimi etkileyen tüm iş akışları (`deploy`, `rollback`) GitHub'ın **`production` ortamına** bağlıdır. Bu ortama bir **required reviewer** tanımlandığında, iş akışı yürütülmeden önce durur ve yetkili birinin onayını bekler. Böylece:

**EN:** All workflows that affect production (`deploy`, `rollback`) are bound to GitHub's **`production` environment**. When a **required reviewer** is defined for it, the workflow pauses before running and waits for an authorized person's approval. As a result:

- **TR:** Hiçbir üretim dağıtımı, kimsenin haberi olmadan tek bir olayla gerçekleşemez. / **EN:** No production deploy can happen through a single event without anyone's awareness.
- **TR:** Onay bekleyen dağıtım GitHub arayüzünde görünür; kim tetikledi, hangi açıklamayla — hepsi kayıtlıdır. / **EN:** A pending deploy is visible in the GitHub UI; who triggered it and with what description — all recorded.
- **TR:** `run-name`, dağıtımı yapanı ve açıklamayı içerir (ör. `Deploy - Dedmoo - ana sayfa güncellendi`). / **EN:** `run-name` includes the actor and description (e.g., `Deploy - Dedmoo - homepage updated`).

**TR — Önerilen `production` ortam sertleştirmesi (Settings → Environments → `production`):** Onay kapısını gerçekten etkili kılmak için şu ayarlar önerilir:

**EN — Recommended `production` environment hardening (Settings → Environments → `production`):** To make the approval gate genuinely effective, the following settings are recommended:

| Ayar / Setting | Neden / Why |
|---|---|
| **Required reviewers** (≥1) | Onaysız üretim dağıtımı olamaz / No unapproved production deploy |
| **Prevent self-review** | Deploy'u tetikleyen kişi kendi dağıtımını onaylayamaz / The triggering actor cannot approve their own deploy |
| **Deployment branches: yalnızca `main` / `main` only** | Yanlışlıkla feature dalından üretime çıkış engellenir / Prevents accidental deploys from a feature branch |
| **Wait timer** (ör. 5–15 dk, opsiyonel) | Onay sonrası "vazgeç" penceresi / A cancel window after approval |

```mermaid
sequenceDiagram
    participant D as Geliştirici / Developer
    participant GH as GitHub Actions
    participant R as Reviewer
    participant P as Production
    D->>GH: Deploy tetikle (açıklama + kaynak)
    GH->>R: Onay iste / request approval
    R-->>GH: Onayla / Approve
    GH->>P: Dağıtımı yürüt / run deployment
    P-->>GH: Sağlık sonucu / health result
```

---

## 5. Sağlık Kontrolü / Health Check

**TR:** Deploy'dan sonra servisin gerçekten çalışıp çalışmadığı `verify-health.sh` ile doğrulanır. Betik, her servisin `health_url`'i için sırasıyla üç göstergeyi dener ve **herhangi biri** olumluysa servisi sağlıklı kabul eder:

**EN:** After deploy, `verify-health.sh` checks whether the service actually runs. For each service's `health_url`, the script tries three indicators in order and considers the service healthy if **any** succeeds:

1. **TR:** `/health` ucu `{"status":"ok"}` döndürüyor mu / **EN:** the `/health` endpoint returns `{"status":"ok"}`
2. **TR:** `/health` HTTP 200 / **EN:** `/health` returns HTTP 200
3. **TR:** Kök `/` HTTP 200 / **EN:** the root `/` returns HTTP 200

**TR:** Kontrol, ayarlanabilir deneme sayısı ve bekleme ile tekrarlanır (varsayılan 12 deneme × 5 sn); servisin başlaması için zaman tanır. Bu tolerans, "servis daha yeni ayağa kalkıyor" ile "servis gerçekten çökmüş" durumlarını ayırt etmeyi sağlar.

**EN:** The check retries with a configurable count and wait (default 12 attempts × 5s), allowing time for the service to start. This tolerance distinguishes "the service is just starting" from "the service is actually down".

---

## 6. Otomatik Geri Alma / Automatic Rollback

**TR:** Deploy sırasında herhangi bir servisin sağlık kontrolü başarısız olursa, boru hattı **kendiliğinden** devreye girer: `*.previous` yedekleri varsa `pipeline.sh rollback` ile bir önceki sürüme döner, tekrar sağlık kontrolü yapar ve işi **başarısız** olarak işaretler. Bu *fail-safe* davranış, hatalı bir dağıtımın kullanıcıya kesinti olarak yansıma süresini en aza indirir — kimsenin gece yarısı müdahale etmesine gerek kalmaz.

**EN:** If any service's health check fails during deploy, the pipeline steps in **automatically**: if `*.previous` backups exist, it reverts to the previous release via `pipeline.sh rollback`, re-checks health, and marks the job as **failed**. This *fail-safe* behavior minimizes the time a faulty deploy is exposed to users — no one has to intervene at midnight.

---

## 7. Manuel Geri Alma / Manual Rollback

**TR:** Ayrıca istediğiniz an bilinçli olarak geri dönebilirsiniz. `production-rollback.yml` iki mod sunar:

**EN:** You can also deliberately revert at any time. `production-rollback.yml` offers two modes:

| Mod / Mode | Ne yapar / What it does | Ne zaman / When |
|---|---|---|
| `previous_folder` | `*.previous` yedeğinden anında dönüş (derleme yok) / Instant revert from backup (no rebuild) | Son dağıtım hatalı, hızlı dönüş gerek / Last deploy faulty, need fast return |
| `specific_commit` | Verilen commit'i derleyip yayımlar / Builds & ships a given commit | Daha eski, belirli bir noktaya dönüş / Return to a specific older point |

**TR:** Her iki modda da sonunda sağlık kontrolü koşulur; geri almanın da sağlıklı sonuç ürettiği doğrulanır. Rollback da `production` onayına tabidir.

**EN:** Both modes run a health check at the end, confirming the rollback itself is healthy. Rollback is also subject to `production` approval.

---

## 8. Denetlenebilirlik / Auditability

**TR:** Her dağıtımda, her servisin dizinine bir `.deploy-info` dosyası yazılır:

**EN:** On every deployment, a `.deploy-info` file is written into each service's directory:

```
deploy_time=2026-07-08T07:46:55Z
commit=abc123...
deployed_by=Dedmoo
note=ana sayfa metni güncellendi
```

**TR:** Böylece "şu an canlıda ne var, kim ne zaman koydu, hangi commit?" sorusu her zaman yanıtlanabilir. Ayrıca GitHub Actions'ın çalışma özeti (`GITHUB_STEP_SUMMARY`) her deploy/rollback için okunabilir bir rapor üretir.

**EN:** So "what is live right now, who put it there and when, which commit?" can always be answered. Additionally, GitHub Actions' run summary (`GITHUB_STEP_SUMMARY`) produces a readable report for each deploy/rollback.

---

## 9. Eşzamanlılık Koruması / Concurrency Guard

**TR:** Deploy ve rollback aynı `concurrency` grubunu (`deploy-<repo>`) paylaşır; böylece aynı anda iki dağıtım/geri alma çalışıp üretim dizinlerinde **yarış koşulu** oluşturması engellenir. CI ise dal başına ayrı bir grup kullanır ve eski çalışmayı iptal ederek çalıştırıcıyı gereksiz yükten korur.

**EN:** Deploy and rollback share the same `concurrency` group (`deploy-<repo>`), preventing two deploys/rollbacks from running at once and causing a **race condition** on production directories. CI uses a per-branch group and cancels the older run to protect the runner from unnecessary load.

---

## Kod yazmazsınız — sadece bilgi girersiniz / No code — you only fill in values

**TR:** Bu şablon **boru hattının kendisidir** (workflow'lar + scriptler); sizin uygulama kodunuzu içermez. Onu kullanmak için **hiçbir dosyayı düzenlemezsiniz.** Projenize özel tüm bilgiler (proje yolları, runner, IP/bağlantı dizeleri, API anahtarları) GitHub arayüzünden **Variables** ve **Secrets** olarak girilir; workflow'lar bunları okur. Bilgileri girdiğiniz an kullanıma hazırdır.

**EN:** This template is **the pipeline itself** (workflows + scripts); it does not contain your application code. To use it you **edit no files.** All project-specific values (project paths, runner, IP/connection strings, API keys) are entered from the GitHub UI as **Variables** and **Secrets**; the workflows read them. It is ready to use the moment you fill them in.

**Settings → Secrets and variables → Actions**

| Tür / Type | Ad / Name | Zorunlu / Required | İçerik / Content |
|---|---|---|---|
| Variable | `DEPLOY_TARGET` | Hayır / No | `local` (varsayılan) veya **`remote`** (uzak sunucu) |
| Variable | `SERVICES` | Evet / Yes | Servis listesi (aşağıya bakın) / service list (see below) |
| Variable | `RUNNER_LABEL` | Hayır / No | `ubuntu-latest` (remote önerilir) veya `self-hosted` |
| Variable | `SSH_HOST` | remote için / for remote | Uzak sunucu IP veya hostname / remote server IP or hostname |
| Variable | `SSH_USER` | remote için / for remote | SSH kullanıcısı (ör. `deploy`) / SSH user (e.g. `deploy`) |
| Variable | `SSH_PORT` | Hayır / No | SSH portu (varsayılan `22`) / SSH port (default `22`) |
| Variable | `SSH_KNOWN_HOSTS` | Önerilir / Recommended | Sunucu host key satırı (`ssh-keyscan` çıktısı); doldurmak bağlantı sıfırlanmalarını önler / server host key line; setting it avoids connection resets |
| Variable | `ARTIFACT_NAME` | Hayır / No | Artifact adı (varsayılan `app-publish`) |
| Secret | `SSH_PRIVATE_KEY` | remote için / for remote | Deploy SSH **private key** (şifresiz bağlantı) |
| Secret | `APP_ENV` | Hayır / No | `KEY=VALUE`: bağlantı dizeleri, API anahtarları |

### `SERVICES` değişkeni / variable

**TR:** Sistemin tamamı bu tek değişkenle yapılandırılır. Her satır bir servisi tanımlar; bir veya N servis desteklenir. Port ve `dll` adı satırlardan otomatik türetilir.

**EN:** The entire system is configured by this single variable. Each line defines one service; one or N services are supported. The port and `dll` name are derived automatically.

```
name|csproj|deploy_dir|service_name|health_url
```

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5200
```

| Alan / Field | Anlamı / Meaning |
|---|---|
| `name` | Servis kimliği (artifact alt klasörü) / service id (artifact subfolder) |
| `csproj` | Yayımlanacak proje / project to publish |
| `deploy_dir` | Host'ta hedef dizin / target dir on host |
| `service_name` | systemd servis adı / systemd service name |
| `health_url` | Sağlık kontrolü taban adresi / health check base URL |

### `APP_ENV` secret'i / secret (opsiyonel / optional)

**TR:** Gizli yapılandırma (bağlantı dizeleri, API anahtarları) burada `KEY=VALUE` satırları olarak tutulur. Deploy sırasında her servisin dizinine `.env` olarak yazılır ve systemd servisine `EnvironmentFile` ile enjekte edilir. .NET, `ConnectionStrings__X` gibi ortam değişkenlerini `appsettings` üzerine otomatik uygular — yani kod değişikliği gerekmez.

**EN:** Secret configuration (connection strings, API keys) is kept here as `KEY=VALUE` lines. At deploy it is written as `.env` into each service dir and injected into the systemd service via `EnvironmentFile`. .NET automatically applies env vars like `ConnectionStrings__X` over `appsettings` — so no code change is needed.

```
ConnectionStrings__CatalogConnection=Server=10.0.0.5,1433;User Id=sa;Password=...;TrustServerCertificate=true
ConnectionStrings__IdentityConnection=Server=10.0.0.5,1433;User Id=sa;Password=...;TrustServerCertificate=true
SomeApi__ApiKey=sk-...
```

---

## Uzak sunucu deploy (SSH) / Remote server deploy (SSH)

**TR:** Üretim sunucuları uzaktaysa (runner'ın yanında değilse) `DEPLOY_TARGET=remote` kullanın. GitHub Actions runner'da derleme yapılır; deploy **SSH key ile şifresiz** uzak sunucuya `rsync` + `systemctl` ile yapılır. Her deploy'da şifre girilmez — private key GitHub **Secret**'ında saklanır.

**EN:** When production servers are remote (not co-located with the runner), use `DEPLOY_TARGET=remote`. Build runs on the GitHub Actions runner; deploy reaches the remote server **passwordlessly via SSH key** using `rsync` + `systemctl`. No password is entered per deploy — the private key is stored as a GitHub **Secret**.

```mermaid
flowchart LR
    GH["GitHub Actions runner<br/>(ubuntu-latest)"] -->|SSH key| SV["Uzak Linux sunucu<br/>Remote Linux server"]
    SV --> SVC["/opt/... + systemd"]
```

### 1. Deploy SSH key oluştur / Create deploy SSH key

**TR** (bir kez, güvenli makinede):

```bash
ssh-keygen -t ed25519 -f deploy_key -N "" -C "cicd-deploy"
```

- `deploy_key` → **private** → GitHub Secret: `SSH_PRIVATE_KEY` (tüm içeriği kopyala)
- `deploy_key.pub` → **public** → uzak sunucuya ekle:

```bash
ssh-copy-id -i deploy_key.pub -p 22 deploy@10.0.0.5
# veya sunucuda: echo "..." >> ~/.ssh/authorized_keys
```

**EN:** Generate once on a secure machine; put the private key in `SSH_PRIVATE_KEY`, public key in the server's `authorized_keys`.

### 2. GitHub Variables / Secrets (remote)

| Ad / Name | Örnek / Example |
|---|---|
| `DEPLOY_TARGET` | `remote` |
| `SSH_HOST` | `10.0.0.5` |
| `SSH_USER` | `deploy` |
| `SSH_PORT` | `22` |
| `RUNNER_LABEL` | `ubuntu-latest` |
| `SSH_PRIVATE_KEY` (Secret) | `deploy_key` dosyasının içeriği |

**TR:** `SERVICES` içindeki `health_url`, runner'ın erişebildiği adres olmalı (ör. `http://10.0.0.5:5001` — `127.0.0.1` değil).

**EN:** In `SERVICES`, `health_url` must be reachable from the runner (e.g. `http://10.0.0.5:5001` — not `127.0.0.1`).

### 3. Uzak sunucuda tek seferlik kurulum / One-time remote host setup

**TR:** systemd birimlerini uzak sunucuda oluşturmak için (SSH ile):

```bash
DEPLOY_TARGET=remote \
SSH_HOST=10.0.0.5 SSH_USER=deploy SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://10.0.0.5:5001" \
bash scripts/setup-remote-host.sh
```

**EN:** Creates systemd units on the remote server over SSH.

### 4. Uzak kullanıcı yetkileri / Remote user permissions

**TR:** Deploy kullanıcısının `sudo` ile `systemctl`, `mkdir`, `cp`, `rm`, `chown` çalıştırabilmesi gerekir (şifresiz önerilir):

```
deploy ALL=(ALL) NOPASSWD: /bin/systemctl, /bin/mkdir, /bin/cp, /bin/rm, /bin/chown
```

`/opt/...` dizinlerine yazma yetkisi de verilmelidir. (`pkill` gerekmez — yeniden başlatma yalnızca `systemctl` ile yapılır.)

**EN:** The deploy user needs passwordless `sudo` for `systemctl`, `mkdir`, `cp`, `rm`, `chown` under `/opt/...`. (`pkill` is not required — restarts use `systemctl` only.)

### Local vs Remote

| | `local` | `remote` |
|---|---|---|
| Runner konumu | Uygulama ile aynı makine | Herhangi (ör. `ubuntu-latest`) |
| Sunucuya SSH | Gerekmez | **SSH key gerekir** |
| `health_url` | `http://127.0.0.1:port` | `http://<sunucu-ip>:port` |
| Kurulum | `setup-host.sh` (yerel) | `setup-remote-host.sh` (SSH) |

### Sorun giderme (uzak/remote bağlantı) / Troubleshooting (remote connection)

**TR:** Uzak sunucuya bağlanırken en sık karşılaşılan durumlar ve çözümleri. Çoğu sorun SSH anahtarı, host doğrulaması veya sudo yetkisi kaynaklıdır.

**EN:** The most common situations when connecting to a remote server, and their fixes. Most issues come from the SSH key, host verification or sudo permissions.

| Belirti / Symptom | Olası neden / Likely cause | Çözüm / Fix |
|---|---|---|
| `kex_exchange_identification: Connection reset by peer` / bağlantı arada sıfırlanıyor | Modern sshd (OpenSSH 9.8+) çok sayıda kısa/doğrulamasız bağlantıyı `PerSourcePenalties` ile cezalandırır. Genelde her adımda `ssh-keyscan` yapılmasından tetiklenir. | `SSH_KNOWN_HOSTS` variable'ını doldurun (aşağıya bakın) — böylece `ssh-keyscan` tekrarlanmaz. Gerekirse sunucuda `sshd_config` → `PerSourcePenalties no` (dikkatli olun). |
| `Host key verification failed` | `StrictHostKeyChecking=yes` açık ve host `known_hosts`'ta yok. | `SSH_KNOWN_HOSTS` variable'ına host anahtarını koyun: `ssh-keyscan -p <port> <host>` çıktısını yapıştırın. |
| `Permission denied (publickey)` | Public key sunucuda yok, yanlış kullanıcı veya izinler hatalı. | `deploy_key.pub`'ı `~<SSH_USER>/.ssh/authorized_keys`'e ekleyin; `SSH_USER` doğru olsun; `chmod 700 ~/.ssh`, `chmod 600 authorized_keys`. |
| `Load key ... invalid format` / `error in libcrypto` | `SSH_PRIVATE_KEY` secret'ı eksik/bozuk yapıştırılmış. | Anahtarın **tümünü** (`-----BEGIN...` ve `-----END...` satırları dahil) yapıştırın. `ed25519` ve **şifresiz** (passphrase yok) key kullanın. |
| `sudo: a password is required` / restart-backup adımı takılıyor | Deploy kullanıcısında şifresiz `sudo` yok. | Sunucuda sudoers (`visudo`): `deploy ALL=(ALL) NOPASSWD: /bin/systemctl, /bin/mkdir, /bin/cp, /bin/rm, /bin/chown`. |
| Health başarısız ama servis ayakta | `health_url` runner'dan erişilemiyor (`127.0.0.1` yazılmış) veya port firewall'da kapalı. | Remote'ta `health_url = http://<sunucu-ip>:port`; güvenlik grubunda/firewall'da o portu runner'a açın. |
| `Connection timed out` | Port/firewall veya yanlış `SSH_HOST`/`SSH_PORT`. | Sunucuda 22 (veya `SSH_PORT`) portunu runner IP'sine açın; `SSH_HOST` ve `SSH_PORT` değerlerini doğrulayın. |
| `rsync: command not found` | rsync runner'da **veya** sunucuda kurulu değil. | İki tarafta da kurun: `sudo apt-get install -y rsync`. |
| İlk deploy'da `App.dll bulunamadı` | `setup-remote-host.sh` çalıştı ama henüz deploy yapılmadı (`/opt/...` boş). | Önce bir Deploy tetikleyin; systemd servisi ilk yayından sonra ayağa kalkar. |

**TR — `SSH_KNOWN_HOSTS` nasıl alınır (tavsiye edilir):**

**EN — How to get `SSH_KNOWN_HOSTS` (recommended):**

```bash
ssh-keyscan -p 22 10.0.0.5
# çıktının tamamını / the whole output ->  Variable: SSH_KNOWN_HOSTS
```

**TR:** Bunu doldurmak hem "host key verification" hatasını hem de tekrarlı `ssh-keyscan` kaynaklı bağlantı sıfırlanmalarını önler. Boş bırakılırsa blueprint host'u ilk adımda bir kez tarar (`known_hosts`'a ekler) ve sonraki adımlarda tekrar taramaz.

**EN:** Setting this avoids both the "host key verification" error and the connection resets caused by repeated `ssh-keyscan`. If left empty, the blueprint scans the host once on the first step (adds it to `known_hosts`) and does not re-scan on later steps.

---

## Kurulum checklist / Setup checklist

**TR:** Aşağıdaki tablo, projeyi kullanıma hazır hâle getirmek için **neyi nerede değiştireceğinizi** özetler. Workflow veya script dosyalarını düzenlemeniz gerekmez.

**EN:** The table below summarizes **what to change where** to make the project ready to use. You do not need to edit workflow or script files.

### Neyi nerede değiştirirsiniz? / What to change where

| Nerede / Where | Ne değişir / What you change | Zorunlu / Required | Kaç kez / How often |
|---|---|---|---|
| GitHub repo → **Use this template** | Yeni repo oluşturma / create your copy | Evet / Yes | 1 kez / once |
| Repo kökü | `templates/.github` → `.github`, `templates/scripts` → `scripts` kopyala / copy | Evet / Yes | 1 kez / once |
| **Settings → Variables** → `DEPLOY_TARGET` | `remote` (uzak sunucu) veya `local` | remote için / for remote | 1 kez |
| **Settings → Variables** → `SSH_HOST`, `SSH_USER` | Uzak sunucu IP ve kullanıcı / remote IP and user | remote için | 1 kez |
| **Settings → Secrets** → `SSH_PRIVATE_KEY` | Deploy SSH private key | remote için | 1 kez |
| **Settings → Variables** → `SERVICES` | Proje yolu, deploy dizini, **health_url = sunucu IP** | Evet / Yes | Proje başına |
| Aynı yer → `RUNNER_LABEL` | `ubuntu-latest` (remote) veya `self-hosted` (local) | Hayır / No | Gerekirse |
| **Settings → Secrets** → `APP_ENV` | DB / API gizli ayarlar | Hayır / No | Gerekirse |
| **Settings → Environments** → `production` | Onaylayan kişi + sertleştirme (self-review engelle, yalnızca `main`) / reviewer + hardening (prevent self-review, `main` only) | Evet / Yes | 1 kez |
| Uzak sunucu (remote) | `bash scripts/setup-remote-host.sh` (SSH ile systemd) | remote için | 1 kez |
| Yerel host (local) | `sudo bash scripts/setup-host.sh` | local için | 1 kez |

### Kullanıma hazır olma sırası / Ready-to-use sequence

**TR (uzak sunucu / remote — önerilen / recommended)**

1. **Use this template** → yeni repo
2. `templates/` içeriğini repo köküne taşı
3. Deploy SSH key oluştur → public key sunucuya, private key → Secret `SSH_PRIVATE_KEY`
4. Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `SERVICES` (health_url = sunucu IP)
5. `RUNNER_LABEL=ubuntu-latest`, `production` + reviewer
6. `bash scripts/setup-remote-host.sh` (bir kez)
7. Push → CI → Deploy + onay

**EN (remote — recommended)**

1. **Use this template** → new repo
2. Move `templates/` to repo root
3. Create deploy SSH key → public on server, private in `SSH_PRIVATE_KEY`
4. Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `SERVICES` (health_url = server IP)
5. `RUNNER_LABEL=ubuntu-latest`, `production` + reviewer
6. `bash scripts/setup-remote-host.sh` (once)
7. Push → CI → Deploy + approve

**TR (yerel / local — runner = sunucu)**

1. [github.com/Dedmoo/dotnet-cicd-template](https://github.com/Dedmoo/dotnet-cicd-template) → **Use this template** → yeni repo oluştur
2. `templates/.github` ve `templates/scripts` klasörlerini repo **köküne** taşı
3. Variables: `DEPLOY_TARGET=local` (veya boş), `SERVICES`, `RUNNER_LABEL=self-hosted`
4. (Opsiyonel) Secret `APP_ENV`
5. **Settings → Environments** → `production` + **required reviewers**
6. Runner makinesinde: `sudo SERVICES="..." bash scripts/setup-host.sh`
7. `main`'e push → CI → Deploy

**EN (local — runner on same machine)**

1. **Use this template** → new repo
2. Move `templates/.github` and `templates/scripts` to repo root
3. Variables: `DEPLOY_TARGET=local` (or empty), `SERVICES`, `RUNNER_LABEL=self-hosted`
4. (Optional) Secret `APP_ENV`
5. **Settings → Environments** → `production` + **required reviewers**
6. On runner machine: `sudo SERVICES="..." bash scripts/setup-host.sh`
7. Push to `main` → CI → Deploy

### Düzenlenmeyen dosyalar / Files you do not edit

**TR:** `continuous-integration.yml`, `production-deploy.yml`, `production-rollback.yml`, `pipeline.sh` ve diğer şablon dosyalarına dokunmayın. Tüm proje bilgileri yalnızca GitHub **Variables** / **Secrets** üzerinden okunur.

**EN:** Do not touch `continuous-integration.yml`, `production-deploy.yml`, `production-rollback.yml`, `pipeline.sh` or other template files. All project values are read only from GitHub **Variables** / **Secrets**.

---

## Uçtan uca senaryolar / End-to-end scenarios

**TR — Bir değişiklik nasıl canlıya çıkar?**
1. Geliştirici `main`'e push eder → CI otomatik derler, test eder, artifact üretir.
2. Actions → **Deploy** → açıklama girilir, kaynak seçilir.
3. `production` onayı verilir.
4. backup → publish → restart → health → sağlıklıysa **canlı**.

**EN — How does a change go live?**
1. Developer pushes to `main` → CI auto builds, tests, produces an artifact.
2. Actions → **Deploy** → enter a description, pick a source.
3. `production` approval is granted.
4. backup → publish → restart → health → if healthy, **live**.

**TR — Hatalı bir deploy olursa ne olur?**
1. Health check başarısız olur.
2. Boru hattı otomatik olarak `*.previous`'a döner.
3. Tekrar health check yapılır, iş "başarısız" işaretlenir.
4. Kullanıcılar önceki çalışan sürümü görmeye devam eder.

**EN — What happens on a bad deploy?**
1. The health check fails.
2. The pipeline auto-reverts to `*.previous`.
3. Health is re-checked, the job is marked "failed".
4. Users keep seeing the previous working version.

---

## Hızlı başlangıç / Quick start

**TR:** Dosya düzenlemeden. Sadece kopyalayın ve arayüzden bilgileri girin:
**EN:** No file editing. Just copy and fill in values from the UI:

1. **TR:** `templates/.github` ve `templates/scripts` klasörlerini kendi deponuzun köküne kopyalayın. / **EN:** Copy `templates/.github` and `templates/scripts` to your repository root.
2. **TR:** GitHub → Settings → Secrets and variables → Actions → **Variables**: `SERVICES` (ve gerekiyorsa `RUNNER_LABEL`) ekleyin. / **EN:** Add the `SERVICES` variable (and `RUNNER_LABEL` if needed).
3. **TR:** (Opsiyonel) **Secrets** → `APP_ENV`: bağlantı dizeleri / API anahtarları. / **EN:** (Optional) Secret `APP_ENV`: connection strings / API keys.
4. **TR:** GitHub → Settings → Environments → `production` ekleyip **required reviewers** tanımlayın; **prevent self-review** ve **yalnızca `main`** dalını açın (onay kapısı sertleştirmesi). / **EN:** Add a `production` environment with **required reviewers**; enable **prevent self-review** and **`main`-only** branch (approval gate hardening).
5. **TR:** Host'ta bir kez (systemd birimlerini kurar) / **EN:** Once on the host (creates systemd units):
   ```bash
   sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
        bash scripts/setup-host.sh
   ```
6. **TR:** `main`'e push edin (CI yeşil), sonra Actions → Deploy'u tetikleyin. / **EN:** Push to `main` (CI green), then Actions → trigger Deploy.

**TR:** Not: `SERVICES` değerini adım 2'de girdiğiniz değişkenden kopyalayıp adım 5'te kullanın (aynı değer). Farklı yığınlar (Node.js, Java) için yalnızca üç komut (build/test, publish, run) değişir — ayrıntılar dokümanda.
**EN:** Note: use the same `SERVICES` value from step 2 in step 5. For other stacks (Node.js, Java) only three commands (build/test, publish, run) change — details in the docs.

---

## Dosya yapısı / File structure

```
dotnet-cicd-template/
├── README.md
├── docs/
│   ├── dotnet-cicd-template.tr.md  # Türkçe playbook
│   └── dotnet-cicd-template.en.md  # English playbook
└── templates/
    ├── .github/
    │   ├── actions/build-test/action.yml     # sürüm doğrulama + cache + build/test
    │   └── workflows/
    │       ├── continuous-integration.yml     # push/PR -> reusable CI
    │       ├── reusable-dotnet-build.yml      # build/test + (opsiyonel) tek artifact
    │       ├── production-deploy.yml          # elle, onaylı, health + otomatik rollback
    │       └── production-rollback.yml        # previous_folder | specific_commit
    └── scripts/
        ├── pipeline.sh            # local + remote deploy/rollback
        ├── ssh-remote.sh          # SSH key, rsync, remote commands
        ├── setup-remote-host.sh   # uzak sunucuda systemd kurulumu (SSH)
        ├── verify-health.sh
        └── setup-host.sh          # yerel systemd kurulumu
```

---

## Dokümantasyon / Documentation

**TR:** Firmaya özel ayarlar (Variables/Secrets/Environments) için tek başvuru noktası:
**EN:** Single reference for company-specific settings (Variables/Secrets/Environments):

| Dil / Language | Belge / Document |
|---|---|
| Türkçe | [`docs/company-setup.tr.md`](./docs/company-setup.tr.md) |
| English | [`docs/company-setup.en.md`](./docs/company-setup.en.md) |

**TR:** Akademik düzeyde, ayrıntılı playbook (mimari, ilkeler, uyarlama rehberi, farklı yığınlar, kısıtlar):
**EN:** Academic-level, detailed playbook (architecture, principles, adaptation guide, other stacks, limitations):

| Dil / Language | Belge / Document |
|---|---|
| Türkçe | [`docs/dotnet-cicd-template.tr.md`](./docs/dotnet-cicd-template.tr.md) |
| English | [`docs/dotnet-cicd-template.en.md`](./docs/dotnet-cicd-template.en.md) |

> **TR:** Somut, doldurulmuş bir örnek için eShopOnWeb uyarlaması referans alınabilir. eShop yalnızca örnektir; bu şablonu kullanmak için gerekli değildir.
> **EN:** For a concrete, filled-in example see the eShopOnWeb adaptation. eShop is only an example; it is not required to use this template.
