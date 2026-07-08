# Firma Kurulum Rehberi — dotnet-cicd-template

**TR:** Bu rehber, `dotnet-cicd-template`'i kendi projenize uyarlamak için gereken **tüm yapılandırma adımlarını tek bir yerde** listeler. Hiçbir YML dosyasına dokunmazsınız; tüm proje bilgileri GitHub arayüzü üzerinden Variables ve Secrets olarak girilir.

**EN:** This guide lists **all configuration steps in one place** to adapt `dotnet-cicd-template` to your project. You do not touch any YML file; all project values are entered via the GitHub UI as Variables and Secrets.

---

## Adım 1 — Repoyu oluştur / Create the repo

1. [github.com/Dedmoo/dotnet-cicd-template](https://github.com/Dedmoo/dotnet-cicd-template) sayfasına git.
2. **Use this template → Create a new repository** ile kendi reponu oluştur.
3. Oluşan repoda `templates/` klasörünü **kök dizine** taşı (`.github/` ve `scripts/` klasörleri kök dizinde olmalı).

> Ağaç yapısı:
> ```
> repo-kökü/
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

## Adım 2 — Repository Variables

**GitHub:** Settings → Secrets and variables → Actions → **Variables** sekmesi → **New repository variable**

| Değişken / Variable | Zorunlu | Örnek değer / Example | Açıklama / Description |
|---|---|---|---|
| `SERVICES` | **Evet** | `web\|src/Web/Web.csproj\|/opt/myapp-web\|myapp-web\|http://127.0.0.1:5001` | Servis listesi, her satır `name\|csproj\|deploy_dir\|service_name\|health_url` formatında. Birden fazla servis için her servis ayrı satırda. |
| `DEPLOY_TARGET` | Hayır | `local` veya `remote` | Varsayılan: `local`. Runner aynı zamanda hedef sunucuysa `local`; ayrı bir sunucuya SSH ile deploy için `remote`. |
| `RUNNER_LABEL` | Hayır | `self-hosted` veya `ubuntu-latest` | Runner etiketi. `local` mod için `self-hosted`; `remote` mod için genellikle `ubuntu-latest`. |
| `ARTIFACT_NAME` | Hayır | `app-publish` | CI artifact adı. Varsayılan `app-publish`; tek servis varsa değiştirmeniz gerekmez. |
| `SSH_HOST` | Remote | `192.168.1.100` veya `myserver.com` | Hedef sunucunun IP veya hostname'i. Yalnızca `DEPLOY_TARGET=remote` için gerekli. |
| `SSH_USER` | Remote | `deploy` | SSH kullanıcı adı. Yalnızca `DEPLOY_TARGET=remote` için gerekli. |
| `SSH_PORT` | Hayır | `22` | SSH portu. Varsayılan `22`. |
| `SSH_KNOWN_HOSTS` | Önerilir | `myserver.com ssh-ed25519 AAAA...` | Sunucunun host key satırı. `ssh-keyscan -p 22 <SSH_HOST>` çıktısını buraya yapıştırın. Bu değer olmazsa her adımda `ssh-keyscan` tekrarlanır; modern SSH sunucularında bağlantı sorununa yol açabilir. |

### `SERVICES` çok satırlı örnek / Multi-line example

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5002
```

GitHub Variables metin kutusuna her servis ayrı satıra yazılır.

---

## Adım 3 — Repository Secrets

**GitHub:** Settings → Secrets and variables → Actions → **Secrets** sekmesi → **New repository secret**

| Secret | Zorunlu | Ne yapıştırılır / What to paste |
|---|---|---|
| `SSH_PRIVATE_KEY` | Remote | `ed25519` formatında **şifresiz** SSH private key. `-----BEGIN OPENSSH PRIVATE KEY-----` ile başlayan ve `-----END OPENSSH PRIVATE KEY-----` ile biten tüm metni yapıştırın. Eksik satır veya boşluk olmadığından emin olun. |
| `APP_ENV` | Hayır | `.env` formatında `KEY=VALUE` satırları. Deploy sırasında her servise `.env` olarak enjekte edilir. Örnek: `DATABASE_URL=postgresql://...` veya `API_KEY=abc123`. |

### SSH key oluşturma / Generating an SSH key

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
# deploy_key      → SSH_PRIVATE_KEY secret'ına yapıştır
# deploy_key.pub  → sunucuda ~/.ssh/authorized_keys'e ekle
```

---

## Adım 4 — `production` Ortamı (Environment)

**GitHub:** Settings → **Environments** → **New environment** → adı `production` yaz → **Configure**

| Ayar / Setting | Değer / Value | Neden / Why |
|---|---|---|
| **Required reviewers** | En az 1 kişi ekleyin | Onaysız üretim dağıtımı engellensin |
| **Prevent self-review** | Açık / Enabled | Deploy'u tetikleyen kişi kendi dağıtımını onaylayamasın |
| **Deployment branches** | `main` dalı seçin | Yanlışlıkla feature dalından üretime çıkış engellensin |
| **Wait timer** | 5–15 dk (opsiyonel) | Onay verdikten sonra "vazgeç" için pencere |

> Onay ekranında **prepare** job'unun özetini (açıklama, commit mesajı, SHA) gördükten sonra onay verin. "Onaylayan kişi Actions run sayfasında prepare özetine bakmadan onay vermesin."

---

## Adım 5 — Host Kurulumu (Tek Sefer)

### Yerel / Local (`DEPLOY_TARGET=local`)

Runner ile hedef sunucu aynı makineyse, runner makinesinde **bir kez** çalıştırın:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
     bash scripts/setup-host.sh
```

Script şunları yapar: systemd servis birimlerini oluşturur, deploy dizinlerini hazırlar, boş bir `.dll` placeholder yazar.

### Uzak / Remote (`DEPLOY_TARGET=remote`)

Deploy runner'dan **SSH ile** hedef sunucuya bağlanarak kurulum yapılır:

```bash
SSH_HOST=192.168.1.100 \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
bash scripts/setup-remote-host.sh
```

**Sunucuda sudoers gereksinimi:** Deploy kullanıcısının şifresiz `sudo` ile aşağıdaki komutları çalıştırabilmesi gerekir:

```
deploy ALL=(ALL) NOPASSWD: /bin/systemctl, /bin/mkdir, /bin/cp, /bin/rm, /bin/chown
```

Ayrıca `/opt/...` dizinlerine yazma yetkisi verilmelidir.

---

## Adım 6 — İlk CI ve Deploy

1. `main` dalına bir push yapın → `continuous-integration.yml` otomatik tetiklenir → yeşil olduğunu doğrulayın.
2. Actions → **Production Deploy** → **Run workflow** → Açıklama girin, **source: `ci_artifact`** seçili bırakın → **Run workflow**.
3. Onaylayan kişi prepare özetini inceleyip onaylar → deploy başlar.

---

## Dokunulmayan dosyalar / Files you do not edit

Aşağıdaki dosyalar şablon tarafından yönetilir; **değiştirmeyin:**

- `continuous-integration.yml`
- `reusable-dotnet-build.yml`
- `production-deploy.yml`
- `production-rollback.yml`
- `pipeline.sh`
- `ssh-remote.sh`
- `verify-health.sh`

Tüm proje bilgileri yalnızca **GitHub Variables / Secrets** üzerinden okunur.

---

## Hızlı kontrol listesi / Quick checklist

- [ ] `SERVICES` variable tanımlı ve doğru formatta
- [ ] `DEPLOY_TARGET` ayarlı (`local` veya `remote`)
- [ ] `RUNNER_LABEL` runner etiketiyle eşleşiyor
- [ ] `production` ortamı oluşturuldu, required reviewers eklendi
- [ ] (`remote` için) `SSH_PRIVATE_KEY` secret yapıştırıldı
- [ ] (`remote` için) `SSH_KNOWN_HOSTS` variable dolduruldu
- [ ] (`remote` için) Sunucuda sudoers yapılandırıldı
- [ ] Host kurulum scripti çalıştırıldı
- [ ] İlk CI yeşil
