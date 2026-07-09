# Firma Kurulum Rehberi — dotnet-cicd-template

Bu dosya **referans rehberdir** (tablolar, hangi değişken ne).  
CI/CD’ye hiç dokunmamış biriyseniz önce tıklaya tıklaya giden şu dosyayı kullanın: [`beginner-walkthrough.tr.md`](./beginner-walkthrough.tr.md)

YML dosyasına dokunmazsınız. Tüm ayarlar GitHub arayüzünden (Variables / Secrets / Environments) ve sunucuda bir kez yapılan kurulumdan gelir.

İngilizce sürüm: [`company-setup.en.md`](./company-setup.en.md)

---

## Hangi yolu seçiyorsunuz?

| Yol | Ne zaman | Bu rehberde |
|---|---|---|
| **Yerel (`local`)** | Runner ile uygulama **aynı** makinede | Adım 1 → 2 (local değişkenler) → 3 (`APP_ENV` opsiyonel) → 4 → 5 Yerel → 6 |
| **Uzak (`remote`)** | Uygulama ayrı bir Linux sunucuda; runner GitHub `ubuntu-latest` | Adım 1 → **Sunucu hazırlığı (zorunlu)** → 2 (remote değişkenler) → 3 (SSH secret) → 4 → 5 Uzak → 6 |

Aşağıdaki **uzak** kritik maddelerin hepsi bu dosyada açıkça yazılıdır:

1. Sunucuda `deploy` kullanıcısı + `NOPASSWD: ALL`
2. `SSH_PRIVATE_KEY` secret (ed25519, şifresiz, BEGIN/END dahil)
3. `SSH_KNOWN_HOSTS` variable (`ssh-keyscan` çıktısı)
4. `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`
5. Environments → `production` + required reviewers

---

## Adım 1 — Repoyu oluştur

1. [github.com/Dedmoo/dotnet-cicd-template](https://github.com/Dedmoo/dotnet-cicd-template) sayfasına gidin.
2. **Use this template → Create a new repository** ile kendi reponuzu oluşturun.
3. Oluşan repoda `templates/` içeriğini **kök dizine** taşıyın (`.github/` ve `scripts/` kökte olmalı). .NET projenizi de aynı kökte tutun (`src/...`).

Beklenen ağaç:

```
repo-kökü/
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
└── src/   # sizin .NET kodunuz
```

---

## Uzak sunucu hazırlığı (yalnızca `remote` — Adım 2'den ÖNCE)

Bu adımlar **hedef Linux sunucuda**, bir kez, root/yönetici ile yapılır. Atlarsanız deploy `Permission denied` veya `sudo: a password is required` ile düşer.

### U1 — `deploy` kullanıcısı + SSH public key

Kendi bilgisayarınızda (veya güvenli bir yerde) anahtar üretin:

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
# deploy_key      → sonra GitHub Secret: SSH_PRIVATE_KEY
# deploy_key.pub  → sunucuya eklenecek
```

Sunucuda:

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
# public key'i ekleyin (içeriği tek satır yapıştırın):
sudo tee /home/deploy/.ssh/authorized_keys < deploy_key.pub
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### U2 — Şifresiz `sudo` (`NOPASSWD: ALL`) — zorunlu

Pipeline her sunucu adımını `sudo bash -c "..."` ile çalıştırır. Dar komut listesi (`systemctl`, `mkdir` …) **yeterli değildir** ve deploy kırılır. Şunu ekleyin:

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
```

Doğrulama (sunucuda):

```bash
sudo -u deploy sudo -n true && echo "sudo OK"
```

Bu tam `sudo` yetkisidir. Daha güvenli tutmak için: `deploy` kullanıcısını yalnızca bu dağıtım sunucusuna özel açın; başka işlerde kullanmayın.

### U3 — Sunucuda ek paketler

Deploy ve sağlık kontrolü için tipik gereksinimler:

```bash
sudo apt-get update
sudo apt-get install -y rsync curl nginx
# .NET runtime/SDK — projenizin hedeflediği sürüm (ör. 8)
```

Firewall: SSH portu (çoğunlukla 22) runner'a açık olsun; uygulama portları (`SERVICES` içindeki `health_url` portları) health check için runner'ın erişebileceği şekilde açık olsun.

### U4 — `SSH_KNOWN_HOSTS` için ham çıktıyı alın

Kendi makinenizden (veya runner'ın erişebildiği yerden):

```bash
ssh-keyscan -p 22 <SUNUCU-IP-VEYA-HOSTNAME>
```

Çıktının **tamamını** kopyalayın; Adım 2'de GitHub Variable olarak yapıştırılacak.

---

## Adım 2 — Repository Variables

**GitHub:** Settings → Secrets and variables → Actions → **Variables** → **New repository variable**

### Her yol için zorunlu

| Değişken | Örnek | Açıklama |
|---|---|---|
| `SERVICES` | aşağıya bakın | Her satır: `name\|csproj\|deploy_dir\|service_name\|health_url` |

`SERVICES` örneği (tek servis):

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
```

İki servis:

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5002
```

**`health_url` formatı (blue-green):**
- **PORT**: nginx'in public portu — `setup-host.sh` bu portu nginx'e atar.
- **PATH**: health endpoint'i (`/health` vb.) — socket sağlık kontrolünde kullanılır.
- **IP**: `setup-host.sh` veya elle test için yazılır; pipeline socket üzerinden kontrol ettiğinden IP kısmını yoksayar.

Örnek: `http://203.0.113.10:5001/health` → nginx port `5001`; health path `/health`.

### Yerel (`local`) ek değişkenler

| Değişken | Değer |
|---|---|
| `DEPLOY_TARGET` | `local` (veya boş bırakın; varsayılan local) |
| `RUNNER_LABEL` | `self-hosted` (runner etiketiniz neyse) |

### Uzak (`remote`) — şu seti mutlaka doldurun

| Değişken | Zorunlu | Değer |
|---|---|---|
| `DEPLOY_TARGET` | **Evet** | `remote` |
| `SSH_HOST` | **Evet** | Sunucu IP veya hostname |
| `SSH_USER` | **Evet** | `deploy` (U1'deki kullanıcı) |
| `SSH_PORT` | Hayır | Varsayılan `22` |
| `SSH_KNOWN_HOSTS` | **Zorunlu (remote)** | U4'teki `ssh-keyscan` çıktısının tamamı |
| `RUNNER_LABEL` | **Evet (önerilen)** | `ubuntu-latest` |
| `ARTIFACT_NAME` | Hayır | Varsayılan `app-publish` — değiştirirseniz CI ile aynı kalır |

`SSH_KNOWN_HOSTS` uzak deploy için **zorunludur**: boş bırakılırsa pipeline çalışmayı reddeder (MITM koruması — eski `ssh-keyscan` otomatik-kabul fallback'i kaldırıldı). Doldurmak ayrıca modern SSH sunucularında (`PerSourcePenalties`) bağlantı sıfırlanmalarını önler.

---

## Adım 3 — Repository Secrets

**GitHub:** Settings → Secrets and variables → Actions → **Secrets** → **New repository secret**

| Secret | Ne zaman | Ne yapıştırılır |
|---|---|---|
| `SSH_PRIVATE_KEY` | **remote zorunlu** | `deploy_key` dosyasının **tümü**: `-----BEGIN OPENSSH PRIVATE KEY-----` … `-----END OPENSSH PRIVATE KEY-----`. Şifresiz (`-N ""`) ed25519. Eksik satır = `invalid format`. |
| `APP_ENV` | Opsiyonel (local + remote) | `KEY=VALUE` satırları (`.env`). Deploy'da her servise `.env` olarak yazılır. |

Private key'i asla Variables'a koymayın; yalnızca Secrets.

---

## Adım 4 — `production` Environment (zorunlu)

**GitHub:** Settings → **Environments** → **New environment** → adı tam olarak `production`

| Ayar | Değer | Neden |
|---|---|---|
| **Required reviewers** | En az 1 kişi | Onaysız üretim dağıtımı olmasın |
| **Prevent self-review** | Açık | Tetikleyen kendi dağıtımını onaylayamasın |
| **Deployment branches** | yalnızca `main` | Feature dalından üretime çıkış olmasın |
| **Wait timer** | 5–15 dk (opsiyonel) | Onay sonrası vazgeç penceresi |

Deploy ve Rollback bu ortama bağlıdır. Onay vermeden önce Actions run sayfasındaki **`prepare` özetini** (açıklama, commit mesajı, SHA) okuyun.

---

## Adım 5 — Host kurulumu (tek sefer)

### Yerel

Runner = sunucu makinesi:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001" \
     bash scripts/setup-host.sh
```

Her servis için: (1) iki systemd birimi (`blue`/`green`, Unix socket üzerinde), (2) nginx upstream include + public-port server bloğu oluşturur. nginx kurulu değilse otomatik kurar. Dizinler ilk deploy'da oluşur; servisler ilk başarılı deploy'dan sonra ayakta kalır.

### Uzak

**Önce** U1–U2 (kullanıcı + sudoers) bitmiş olmalıdır. Sonra (SSH ile erişebildiğiniz bir makineden, private key elinizdeyken):

```bash
SSH_HOST=<SUNUCU-IP> \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://<SUNUCU-IP>:5001" \
bash scripts/setup-remote-host.sh
```

`SERVICES` içindeki `health_url` burada da aynı format olmalıdır. Bu script uzak sunucuda `setup-host.sh` çalıştırır; nginx + iki renk systemd birimini oluşturur.

---

## Adım 6 — İlk CI ve Deploy

1. `main`'e push → Actions'ta **Continuous Integration** yeşil olsun.
2. Actions → **Production Deploy** → **Run workflow** → zorunlu açıklama yazın → kaynak `ci_artifact` kalsın → Run.
3. Reviewer `prepare` özetini okuyup onaylasın → deploy koşar.
4. Health fail olursa nginx geçişi **yapılmaz**; canlı etkilenmez; job kırmızıya çeker. Sorunu giderin, yeniden deploy tetikleyin.

İlk kurulumda henüz CI artifact yoksa bir kez `build_from_source` kullanabilirsiniz; sonraki normale `ci_artifact` dönün.

---

## Dokunulmayan dosyalar

Şunları düzenlemeyin — proje bilgisi YML satırına yazılmaz:

- `continuous-integration.yml`
- `reusable-dotnet-build.yml`
- `production-deploy.yml`
- `production-rollback.yml`
- `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`

---

## Hızlı kontrol listesi

### Ortak
- [ ] Template → yeni repo; `templates/` kökte
- [ ] `SERVICES` doğru formatta
- [ ] `production` environment: required reviewers + prevent self-review + `main` only
- [ ] `nginx` sunucuda kurulu (`setup-host.sh` kurar veya önceden kurulmuş)
- [ ] Continuous Integration en az bir kez yeşil
- [ ] Production Deploy açıklama ile tetiklendi / onaylandı

### Remote ek checklist
- [ ] Sunucuda `deploy` kullanıcısı + `authorized_keys`
- [ ] `deploy ALL=(ALL) NOPASSWD: ALL` doğrulandı (`sudo -n true`)
- [ ] `rsync` (+ .NET) sunucuda kurulu
- [ ] Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`
- [ ] Variable: `SSH_KNOWN_HOSTS` = `ssh-keyscan` çıktısı
- [ ] Secret: `SSH_PRIVATE_KEY` = private key tam metin (BEGIN/END)
- [ ] `SERVICES` health_url PORT = nginx'in public portu; PATH = health endpoint (`/health`)
- [ ] Sunucuda `nginx` kurulu (veya `setup-host.sh` kurdu)
- [ ] `setup-remote-host.sh` bir kez çalıştı
