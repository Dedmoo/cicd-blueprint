# Kendi Projene Entegrasyon — Tam Kurulum Rehberi (Sıfırdan)

Bu rehber, **dotnet-cicd-template** (blueprint) CI/CD sistemini **kendi .NET projenize**
sıfırdan kurmak isteyen herkes içindir. Hiç CI/CD, GitHub Actions, Linux veya nginx
bilmeseniz bile adım adım takip ederek kurabilirsiniz.

> **Not:** `eShopOnWeb` (cicd-eshop) yalnızca **tanıtım/örnek** amaçlıdır. Bu sistemi
> kullanmak için eShop'a ihtiyacınız yok. Aşağıda kendi projenizi bağlarsınız.

Bu rehber, **video'da gösterilmeyen** her şeyi (sunucu kurulumu, GitHub'a bağlama,
hangi kodun nereye konacağı) uçtan uca anlatır. Video yalnızca günlük akışı gösterir:
`kod değiştir → commit → push → CI → onay → canlı güncellendi`.

İlgili diğer belgeler (aynı bilgi, farklı biçim):
- Tıkla-tıkla, uzak sunucu odaklı: [`beginner-walkthrough.tr.md`](./beginner-walkthrough.tr.md)
- Referans tablolar (hangi değişken ne): [`company-setup.tr.md`](./company-setup.tr.md)
- Akademik/derin playbook: [`dotnet-cicd-template.tr.md`](./dotnet-cicd-template.tr.md)
- English version: [`own-project-integration.en.md`](./own-project-integration.en.md)

---

## İçindekiler

1. [Sistem ne yapıyor? (kavram)](#1-sistem-ne-yapıyor-kavram)
2. [Sözlük](#2-sözlük)
3. [İki dağıtım modeli: local ve remote](#3-iki-dağıtım-modeli-local-ve-remote)
4. [İhtiyaç listesi](#4-i̇htiyaç-listesi)
5. [Adım A — Blueprint'i kendi reponuza alma](#5-adım-a--blueprinti-kendi-reponuza-alma)
6. [Adım B — Kodunuzu hazırlama (hangi kod nereye)](#6-adım-b--kodunuzu-hazırlama-hangi-kod-nereye)
7. [Adım C — SERVICES satırını yazma](#7-adım-c--services-satırını-yazma)
8. [Adım D — Sunucuyu hazırlama (remote)](#8-adım-d--sunucuyu-hazırlama-remote)
9. [Adım E — GitHub ayarları (Variables / Secrets / Environment)](#9-adım-e--github-ayarları-variables--secrets--environment)
10. [Adım F — Runner (kim komutu çalıştırır?)](#10-adım-f--runner-kim-komutu-çalıştırır)
11. [Adım G — Sunucuya tek seferlik kurulum scripti](#11-adım-g--sunucuya-tek-seferlik-kurulum-scripti)
12. [Adım H — İlk CI ve ilk Deploy](#12-adım-h--i̇lk-ci-ve-i̇lk-deploy)
13. [Günlük iş akışı (video'daki kısım)](#13-günlük-iş-akışı-videodaki-kısım)
14. [Geri alma (Rollback)](#14-geri-alma-rollback)
15. [Güvenlik modeli (bilmeniz gerekenler)](#15-güvenlik-modeli-bilmeniz-gerekenler)
16. [Sorun giderme](#16-sorun-giderme)
17. [Kurulum bitti — kontrol listesi](#17-kurulum-bitti--kontrol-listesi)

---

## 1. Sistem ne yapıyor? (kavram)

Amaç: **yeni sürümü kesintisiz canlıya almak.** Kullanıcı siteyi kullanırken veya F5
yaptığında güncellemeyi görür; "duyuru yapıp uygulamayı elle kapatın" diye bir süreç yoktur.

Akış:

1. Kodu GitHub'a **push** edersiniz → GitHub otomatik **derler + test eder** (CI).
2. Canlıya çıkmak için yetkili biri **Deploy**'u elle başlatır ve **onaylar**.
3. Onaydan sonra yeni sürüm sunucudaki **boş renge (blue/green)** yazılır.
4. Yeni renk **sağlık kontrolünden** geçerse nginx trafiği **sessizce** yeni renge çevirir.
5. Sağlık kontrolü **geçemezse** geçiş **yapılmaz**; kullanıcılar eski sürümü kesintisiz görür.

### Blue-green nedir?

Her servis için sunucuda **iki kopya** çalışır: `blue` ve `green`. Bir an için **yalnızca biri
canlıdır** (nginx trafiği ona yönlendirir). Deploy, **boşta (idle)** olan renge yazar; sağlık
onaylanınca nginx **o renge** geçer. Eski renk kapanmaz — **anlık geri dönüş** hedefidir.

```
                 nginx (public port)
                        |
              ┌─────────┴─────────┐
        (canlı) ▼                 ▼ (idle / yeni sürüm buraya)
       cicd-web-blue.sock   cicd-web-green.sock
        [uygulama v1]         [uygulama v2]
```

---

## 2. Sözlük

| Kelime | Basit anlamı |
|---|---|
| **Repo** | GitHub'daki proje klasörü |
| **Commit** | "Şu değişikliği kaydettim" demek |
| **Push** | Kaydettiğiniz değişikliği GitHub'a göndermek |
| **CI** | Otomatik derleme + test (Continuous Integration) |
| **Deploy** | Yeni sürümü canlı sunucuya koymak |
| **Artifact** | CI'nin ürettiği, saklanan derleme çıktısı |
| **Runner** | Actions komutlarının çalıştığı bilgisayar |
| **Variable** | GitHub'da görünen ayar metni (IP gibi) |
| **Secret** | GitHub'da gizli ayar (SSH anahtarı); loglarda görünmez |
| **Environment** | "Canlıya çıkmadan onay iste" kutusu (`production`) |
| **SSH** | Uzak Linux sunucuya güvenli bağlantı |
| **nginx** | Trafiği uygulamaya yönlendiren web sunucusu |
| **systemd** | Linux'ta uygulamayı servis olarak aç/kapat yapan sistem |
| **Unix socket** | Uygulamanın TCP portu yerine dinlediği yerel dosya soketi |

---

## 3. İki dağıtım modeli: local ve remote

Kurulumdan önce hangi modeli kullandığınıza karar verin. Fark, `DEPLOY_TARGET` değişkeninde.

| Model | Ne zaman | Runner | GitHub'da `DEPLOY_TARGET` |
|---|---|---|---|
| **remote** (önerilen) | Uygulama **ayrı bir Linux sunucuda** | GitHub'ın `ubuntu-latest` runner'ı (kurulum gerekmez) | `remote` |
| **local** | Runner **ile** uygulama **aynı** makinede | O makineye kurduğunuz **self-hosted** runner | `local` |

- **remote** çoğu şirket için doğru seçenektir: GitHub'ın hazır runner'ı SSH ile sizin
  sunucunuza bağlanıp deploy eder. Sunucuya runner kurmanıza gerek yoktur.
- **local**, sunucunun kendisinde bir self-hosted runner çalıştırdığınız durumdur (ör. tek
  makinelik ortam). SSH gerekmez; runner doğrudan yerelde çalışır.

> Bu rehber esas olarak **remote**'u anlatır ve gereken yerde local farkını belirtir.

---

## 4. İhtiyaç listesi

**Herkes:**
- [ ] Bir **GitHub hesabı** (ücretsiz yeterli)
- [ ] Template'i kendi hesabınıza kopyalama izni
- [ ] Kendi bilgisayarınızda bir terminal (Windows: PowerShell veya WSL/Git Bash; Mac/Linux: Terminal)
- [ ] **.NET SDK** (projenizin sürümü, ör. .NET 8) — yerelde derlemek/test etmek için

**remote modeli için ek:**
- [ ] Bir **Linux sunucu** (IP/hostname, SSH ile girilebilir)
- [ ] Sunucuya **root/sudo** ile girebilme

Kim ne yapar?
- **IT / DevOps:** Adım D, F, G (bir kez).
- **Geliştirici:** Adım B, C + günlük iş.
- **Onaylayıcı:** Deploy sırasında GitHub'dan **Approve** basar.

---

## 5. Adım A — Blueprint'i kendi reponuza alma

1. Tarayıcıda açın: <https://github.com/Dedmoo/dotnet-cicd-template>
2. Yeşil **Use this template → Create a new repository**.
3. Repo adı verin (ör. `sirketim-uygulama`) → **Create repository**.
4. Yeni repoda bir `templates/` klasörü göreceksiniz. **İçindeki her şeyi repo köküne taşıyın:**
   - `.github/` klasörü **kökte** olmalı
   - `scripts/` klasörü **kökte** olmalı

Taşıma sonrası beklenen ağaç:

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
└── src/            # sizin .NET kodunuz (Adım B)
```

> **Neden taşıyoruz?** GitHub Actions yalnızca **repo kökündeki** `.github/workflows/`
> klasörünü çalıştırır. `templates/.github/` altında dururken tetiklenmez.

**Kontrol:** Repo kökünde `.github/workflows/production-deploy.yml` var mı? Evet → devam.

### Dokunulmayan dosyalar

Şu dosyaları **düzenlemeyin** — proje bilgisi YML satırına yazılmaz, GitHub arayüzünden gelir:

- `continuous-integration.yml`, `reusable-dotnet-build.yml`
- `production-deploy.yml`, `production-rollback.yml`
- `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`

---

## 6. Adım B — Kodunuzu hazırlama (hangi kod nereye)

Blueprint, standart bir ASP.NET Core (.NET) uygulaması varsayar. Kodunuzda **iki küçük şart**
sağlamanız gerekir. Bunların dışında normal projenizi kullanırsınız.

### 6.1 Kodun yeri

.NET projenizi repo köküne koyun. Örnek yapı (sizin adlarınız farklı olabilir):

```
repo-kökü/
├── src/
│   └── Web/
│       ├── Web.csproj      # <-- SERVICES içinde bu yolu vereceksiniz
│       └── Program.cs
```

`.csproj` yolunuzu not edin (ör. `src/Web/Web.csproj`); Adım C'de kullanacaksınız.

### 6.2 Şart 1 — Uygulama, verilen adrese bağlanabilmeli (URL'i sabitlemeyin)

Sunucuda uygulama bir **Unix socket** üzerinden dinler. systemd bunu şu şekilde başlatır:

```
dotnet <yol>/Web.dll --urls http://unix:/run/cicd/<servis>-<renk>.sock
```

ASP.NET Core Kestrel `--urls` parametresini otomatik uygular. **Yapmanız gereken:** Program.cs
içinde adresi **sabitlememek.** Yani şunlar **olmamalı:**

```csharp
// YANLIŞ — --urls'i ezer, socket bağlanmaz:
builder.WebHost.UseUrls("http://localhost:5000");
```

`launchSettings.json` yalnızca geliştirme (dev) içindir, canlıda yok sayılır — sorun değil.
Kısaca: adres verme kodunu kaldırın, `--urls` kendiliğinden çalışır.

### 6.3 Şart 2 — Bir "health" (sağlık) adresi 200 dönmeli

Deploy, yeni sürümün ayağa kalktığını **socket üzerinden** `health_url`'deki path'e istek atıp
**HTTP 200** bekleyerek anlar. Uygulamanız o path'te 200 dönmelidir.

En basit yol — Program.cs'e tek satır (ASP.NET Core 6+ minimal API):

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// Sağlık ucu: deploy bunu 200 bekler.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

// ... diğer route'larınız ...
app.Run();
```

Alternatif: Zaten ana sayfanız (`/`) 200 dönüyorsa, `health_url` path'ini `/` yapıp ayrı bir
health ucu eklemeyebilirsiniz. Ama ayrı `/health` **önerilir** (bağımlılık kontrolü ekleyebilirsiniz).

> `verify-health.sh` scripti manuel testte `/health` gövdesinde `"status":"ok"`, sonra HTTP 200,
> sonra `/` 200 sırasıyla dener. Deploy içindeki otomatik kontrol ise doğrudan **HTTP 200** arar.

### 6.4 (Opsiyonel) Ortam değişkenleri / bağlantı dizeleri

Gizli ayarları (veritabanı bağlantısı, API anahtarı) koda yazmayın. Bunları GitHub'da
`APP_ENV` **secret**'ına `KEY=VALUE` satırları olarak koyarsınız (Adım E). Deploy bunları her
servis klasörüne bir `.env` dosyası olarak yazar ve systemd uygulamaya ortam değişkeni olarak verir.

ASP.NET Core, iç içe ayarları çift alt çizgi ile okur. Örnek:

```
ConnectionStrings__Default=Server=...;Database=...;User Id=...;Password=...
MyApi__Key=sk-...
```

Kodda normal şekilde `builder.Configuration.GetConnectionString("Default")` ile erişirsiniz.

---

## 7. Adım C — SERVICES satırını yazma

`SERVICES`, sistemin kalbidir. **Her satır bir servis** tanımlar ve **beş alan** içerir,
`|` (dik çizgi) ile ayrılır:

```
name|csproj|deploy_dir|service_name|health_url
```

| Alan | Örnek | Anlamı |
|---|---|---|
| `name` | `web` | Kısa ad (artifact klasörü + etiket) |
| `csproj` | `src/Web/Web.csproj` | Derlenecek proje dosyasının repo içindeki yolu |
| `deploy_dir` | `/opt/myapp-web` | Sunucuda kurulum klasörü (kök yol) |
| `service_name` | `myapp-web` | systemd servis adı |
| `health_url` | `http://SUNUCU_IP:5001/health` | nginx **public portu** + **health path** |

`health_url` özel — üç parçası şu işe yarar:

- **PORT** (`5001`): nginx'in dışarıya açtığı port. `setup-host.sh` bu portu nginx'e atar.
- **PATH** (`/health`): sağlık kontrolünde kullanılan path.
- **IP**: elle test için yazılır; **pipeline socket üzerinden kontrol ettiği için IP'yi yoksayar.**

### Tek servis örneği

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://203.0.113.10:5001/health
```

### İki servis örneği (Variable kutusunda Enter ile alt satır)

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://203.0.113.10:5001/health
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://203.0.113.10:5002/health
```

### Alan kuralları (script doğrular)

- `deploy_dir`: yalnızca `harf, rakam, / _ . @ -` karakterleri.
- `service_name`: yalnızca `harf, rakam, _ . @ -` karakterleri.
- Geçersiz karakter → pipeline başlamadan hata verir (komut enjeksiyonuna karşı).

### Bu satırdan sunucuda ne oluşur? (kavramak için)

`deploy_dir=/opt/myapp-web`, `service_name=myapp-web` verdiğinizde `setup-host.sh` şunları kurar:

- Klasörler: `/opt/myapp-web-blue` ve `/opt/myapp-web-green`
- systemd birimleri: `myapp-web-blue.service`, `myapp-web-green.service`
- Socket'ler: `/run/cicd/myapp-web-blue.sock`, `/run/cicd/myapp-web-green.sock`
- Düşük yetkili sistem kullanıcısı: `cicd-myapp-web` (uygulama **root değil** bununla çalışır)
- nginx: `5001` portunu dinler, aktif renge yönlendirir
- Aktif renk durum dosyası: `/etc/nginx/cicd/myapp-web.active`

---

## 8. Adım D — Sunucuyu hazırlama (remote)

> **local modelinde** bu bölümü atlayın; sunucu = runner makinesi. Yalnızca Adım G'deki
> `setup-host.sh`'i o makinede çalıştırırsınız.

Aşağıdakiler **hedef Linux sunucuda**, **bir kez**, root/sudo ile yapılır.

### D.1 — SSH anahtarı üretin (kendi bilgisayarınızda)

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
```

İki dosya oluşur:
- `deploy_key` → **gizli**. GitHub Secret `SSH_PRIVATE_KEY` olacak.
- `deploy_key.pub` → **açık**. Sunucuya koyacağız.

`deploy_key` içeriğini görün (tamamını sonra kopyalayacaksınız):

```bash
cat deploy_key            # Linux / Mac / WSL
Get-Content deploy_key    # Windows PowerShell
```

`-----BEGIN OPENSSH PRIVATE KEY-----` ile başlayıp `-----END OPENSSH PRIVATE KEY-----` ile
bitmelidir. Tümünü (BEGIN/END dahil) alacaksınız.

### D.2 — Sunucuda `deploy` kullanıcısı + açık anahtar

Sunucuya girin: `ssh root@SUNUCU_IP`

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

Kendi bilgisayarınızda `cat deploy_key.pub` çıktısını (tek satır) kopyalayın, sunucuda
`YAPISTIR` yerine koyun:

```bash
echo "YAPISTIR" | sudo tee /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### D.3 — Şifresiz sudo (`NOPASSWD: ALL`) — zorunlu

Pipeline her sunucu adımını `sudo bash -c "..."` ile çalıştırır; bu yüzden `deploy` kullanıcısı
tam sudo ister. Eksikse deploy `sudo: a password is required` ile kırılır.

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
sudo -u deploy sudo -n true && echo "sudo OK"
```

`sudo OK` görmeden devam etmeyin.

> **Güvenlik notu:** Bu geniş bir yetkidir. `deploy` kullanıcısını **yalnızca bu dağıtım
> sunucusuna özel** açın, başka işte kullanmayın. Uygulama zaten **root çalışmaz** (bkz. Bölüm 15).

### D.4 — Gerekli paketler

```bash
sudo apt-get update
sudo apt-get install -y rsync curl nginx
# Ayrıca projenizin hedeflediği .NET runtime/SDK (ör. .NET 8) kurulu olmalı
```

> `nginx` yoksa `setup-host.sh` otomatik kurar; önceden kurulu olması da sorun değil.
> Firewall: SSH portu (22) ve `SERVICES`'teki health portları runner'ın erişebileceği şekilde açık olmalı.

### D.5 — Host kimliğini alın (`SSH_KNOWN_HOSTS`) — zorunlu

**Kendi bilgisayarınızda** (sunucudan çıkmışken):

```bash
ssh-keyscan -p 22 SUNUCU_IP
```

Çıkan **tüm satırları** kopyalayın; Adım E'de Variable olarak yapıştıracaksınız.

> `SSH_KNOWN_HOSTS` **zorunludur.** Boş bırakılırsa pipeline çalışmayı reddeder (ortadaki-adam
> saldırısına karşı koruma). Eski "otomatik kabul" davranışı güvenlik için kaldırılmıştır.

---

## 9. Adım E — GitHub ayarları (Variables / Secrets / Environment)

Repoda üstte **Settings**.

### E.1 — Variables (görünen ayarlar)

**Settings → Secrets and variables → Actions → Variables → New repository variable**

**Her model için:**

| Name | Value |
|---|---|
| `SERVICES` | Adım C'deki satır(lar) |
| `EF_PROJECT` | Migration içeren `.csproj` (ör. `src/Infrastructure/Infrastructure.csproj`) |
| `EF_STARTUP_PROJECT` | (opsiyonel) Startup `.csproj`; boşsa `SERVICES` ilk csproj |

**remote için ek:**

| Name | Value |
|---|---|
| `DEPLOY_TARGET` | `remote` |
| `SSH_HOST` | Sunucu IP/hostname (ör. `203.0.113.10`) |
| `SSH_USER` | `deploy` |
| `SSH_PORT` | `22` (farklıysa onu) |
| `SSH_KNOWN_HOSTS` | Adım D.5'teki `ssh-keyscan` çıktısının tamamı |
| `RUNNER_LABEL` | `ubuntu-latest` |
| `ARTIFACT_NAME` | (opsiyonel) varsayılan `app-publish` |

**local için ek:**

| Name | Value |
|---|---|
| `DEPLOY_TARGET` | `local` (veya boş; varsayılan local) |
| `RUNNER_LABEL` | `self-hosted` (runner etiketiniz) |

### E.2 — Secrets (gizli ayarlar)

**Settings → Secrets and variables → Actions → Secrets → New repository secret**

| Name | Ne zaman | Value |
|---|---|---|
| `SSH_PRIVATE_KEY` | remote zorunlu | `deploy_key` dosyasının **tümü** (BEGIN…END dahil) |
| `APP_ENV` | opsiyonel | `KEY=VALUE` satırları (bağlantı dizesi vb.) |

> Private key'i **asla** Variables'a koymayın; yalnızca Secrets.

### E.3 — `production` Environment (onay kapısı) — zorunlu

**Settings → Environments → New environment** → adı **tam olarak** `production`

| Ayar | Değer | Neden |
|---|---|---|
| **Required reviewers** | En az 1 kişi | Onaysız üretim dağıtımı olmasın |
| **Prevent self-review** | Açık | Tetikleyen kendi deploy'unu onaylamasın |
| **Deployment branches** | yalnızca `main` | Feature dalından üretime çıkış olmasın |
| **Wait timer** | (opsiyonel) 5–15 dk | Onay sonrası vazgeçme penceresi |

Deploy ve Rollback bu ortama bağlıdır.

---

## 10. Adım F — Runner (kim komutu çalıştırır?)

**remote (RUNNER_LABEL=ubuntu-latest):** Ekstra kurulum **yok.** GitHub'ın barındırdığı
`ubuntu-latest` runner'ı işi yapar; SSH ile sizin sunucunuza bağlanır. En kolay yol budur.

**local (RUNNER_LABEL=self-hosted):** İşleri çalıştıracak makineye bir **self-hosted runner**
kurmanız gerekir:

1. Repo → **Settings → Actions → Runners → New self-hosted runner → Linux**.
2. Ekranda çıkan komutları o makinede çalıştırın (indir → `./config.sh --url ... --token ...`).
3. Servis olarak çalıştırın:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status     # active (running) olmalı
```

4. **Settings → Actions → Runners**'da yeşil/`Idle` görünmeli.

> CI, `dotnet`'i runner'da kurulu varsayar (ayrıca `setup-dotnet` çalıştırmaz).
> `ubuntu-latest` güncel bir .NET SDK ile gelir; belirli bir sürüm gerekiyorsa repoya
> `global.json` koyun. self-hosted runner'da `dotnet --version` ile sürümü doğrulayın.

---

## 11. Adım G — Sunucuya tek seferlik kurulum scripti

Bu script sunucuda **systemd birimlerini ve nginx yapılandırmasını** oluşturur. **Bir kez** çalıştırılır.

### remote

Kendi bilgisayarınızda, repo kökünde (`scripts/` ve `deploy_key` yanınızdayken):

```bash
SSH_HOST=SUNUCU_IP \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_KNOWN_HOSTS="$(ssh-keyscan -p 22 SUNUCU_IP)" \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SUNUCU_IP:5001/health" \
bash scripts/setup-remote-host.sh
```

Windows'ta `bash` yoksa **WSL** veya **Git Bash** kullanın.

### local

Sunucunun (runner'ın) kendisinde:

```bash
sudo SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001/health" \
     bash scripts/setup-host.sh
```

### Script ne yapar?

Her servis için:
1. Düşük yetkili sistem kullanıcısı (`cicd-<servis>`) oluşturur.
2. İki systemd birimi kurar (`<servis>-blue`, `<servis>-green`) — Unix socket üzerinde dinler,
   `User=cicd-<servis>` ile **root olmadan** çalışır, systemd sertleştirmesiyle.
3. nginx upstream include + public-port server bloğu yazar (varsayılan renk: blue).
4. Aktif renk durum dosyasını (`/etc/nginx/cicd/<servis>.active`) `blue` ile başlatır.

Bittiğinde uygulama klasörleri **boş** olabilir — normal; ilk deploy doldurur. Servisler ilk
başarılı deploy'dan sonra ayağa kalkar.

---

## 12. Adım H — İlk CI ve ilk Deploy

### H.0 — Veritabanı migration (EF Core)

Migration deploy akışının parçasıdır; script düzenlemeniz gerekmez.

**Doğru sıra (blue-green):**

1. **Migration** — geriye uyumlu şema değişikliği (aktif renk hâlâ çalışırken)
2. **Idle renge yayın** — yeni kod idle dizine yazılır
3. **Restart + health** — idle socket sağlıklı mı?
4. **Switch** — nginx graceful reload

> **Kritik:** Geriye uyumlu olmayan (breaking) migration'lar blue-green ile doğrudan çalışmaz.
> Expand-contract deseni kullanın veya ayrı bakım penceresi planlayın.

**Kurulum (yalnızca Variables/Secrets):**

1. GitHub **Variables** → `EF_PROJECT` = migration içeren `.csproj` yolu
   (ör. `src/Infrastructure/Infrastructure.csproj`).
2. (Opsiyonel) `EF_STARTUP_PROJECT` = startup `.csproj`. Boş bırakırsanız `SERVICES` ilk
   satırındaki csproj kullanılır.
3. **Secrets** → `APP_ENV` içinde bağlantı dizesi (ör.
   `ConnectionStrings__DefaultConnection=Server=...`).
4. Deploy çalıştırın — `dotnet ef database update` runner üzerinde, artifact indirmeden **önce**
   koşar (uzak sunucuda SDK gerekmez).

`EF_PROJECT` tanımlı değilse migration adımı atlanır.

### H.1 — CI (otomatik)

`main` dalına küçük bir değişiklik push edin. **Actions → Continuous Integration**'ın
**yeşil** olmasını bekleyin. CI otomatik çalışır; `main`'e push'ta ayrıca **artifact** üretir.

Kırmızıysa: kırmızı adıma tıklayıp logu okuyun (çoğu zaman yanlış `SERVICES` yolu veya
runner'da .NET sürümü).

### H.2 — Deploy (elle + onaylı)

Deploy **otomatik değildir**; bilinçli bir eylemdir.

1. **Actions → Production Deploy → Run workflow**.
2. **Açıklama** yazın (zorunlu), ör. `ilk canlı deneme`.
3. **Source:**
   - `ci_artifact` (varsayılan/önerilen) — CI'nin ürettiği artifact'ı kullanır. **Şart:**
     o commit için başarılı bir CI çalışması olmalı (aksi halde deploy commit uyuşmazlığı ile durur).
   - `build_from_source` — kaynağı deploy anında derler. İlk kez CI artifact yoksa bunu bir kez seçin.
4. **Run workflow**.
5. Önce **prepare** adımı yeşile döner ve bir **onay özeti** (kim, açıklama, commit, SHA) yazar.
6. Onaylayıcı özeti okur → **Review deployments → Approve**.
7. Deploy koşar: idle renge yazar → sağlık kontrolü → geçerse nginx'i çevirir.

Başarılıysa uygulamanız `health_url` adresinden cevap verir.

---

## 13. Günlük iş akışı (video'daki kısım)

Kurulum bittikten sonra her değişiklikte:

1. Kodu değiştir (editörünüzde).
2. `git add .`
3. `git commit -m "ne değişti"`
4. `git push origin main`
5. **Actions → Continuous Integration** yeşil olsun.
6. **Actions → Production Deploy → Run workflow** → açıklama → `ci_artifact` → Run.
7. Onaylayıcı **Approve**.
8. Siteyi kontrol edin (F5).

Video yalnızca bu akışı gösterir.

---

## 14. Geri alma (Rollback)

**Actions → Production Rollback → Run workflow** ile iki mod:

| Mod | Ne yapar |
|---|---|
| `previous_folder` | nginx'i **diğer renge** (önceki sürüm) anında çevirir — derleme yok, sıfır kesinti |
| `specific_commit` | Belirtilen commit'i idle renge derler/yayınlar, sağlık geçince çevirir (`commit_sha` girin) |

`previous_folder` en hızlısıdır: eski renk zaten ayakta olduğu için trafik anında geri döner.
Rollback da `production` onayına tabidir.

Rollback **switch öncesi** şunları doğrular (pipeline içinde otomatik):
- Hedef renk dizini mevcut **ve** içinde publish DLL dosyası var (boş klasörle rollback yapılmaz)
- Hedef renk socket'i health check'ten geçiyor (sağlıksız sürüme trafik verilmez)
- nginx reload veya state yazımı başarısız olursa upstream otomatik eski renge geri alınır

> **Önemli:** `previous_folder` yalnızca **diğer renkte daha önce başarılı bir deploy yapılmışsa** çalışır.
> İlk deploy'dan hemen sonra (yalnızca bir renk doluysa) rollback hedefi bulunamaz ve işlem
> hiçbir değişiklik yapmadan iptal olur — bu beklenen davranıştır. İkinci deploy'dan sonra
> her iki renk de dolu olur ve anında rollback mümkün hale gelir.

---

## 15. Güvenlik modeli (bilmeniz gerekenler)

Bu sistem güvenlik açısından sertleştirilmiştir; bilmeniz gerekenler:

- **Uygulama root çalışmaz.** Her servis kendi düşük yetkili `cicd-<servis>` kullanıcısıyla
  çalışır; systemd sertleştirmesi (`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`,
  `PrivateTmp` …) uygulanır. Uygulamada bir açık, doğrudan root'a dönüşmez.
- **`SSH_KNOWN_HOSTS` zorunludur.** Sunucu kimliği önceden doğrulanmadan uzak deploy yapılmaz.
- **Provenance (köken doğrulama).** `ci_artifact` ile deploy edilirken, artifact'ı üreten CI
  commit'i ile deploy edilen commit **aynı** olmalıdır; değilse deploy durur.
- **Onay kapısı.** Üretim deploy/rollback `production` environment onayı ister; `prevent
  self-review` ile tetikleyen kendi işini onaylayamaz.
- **En az yetki.** Workflow'lar yalnızca gereken okuma izinleriyle çalışır; action'lar sabit
  commit SHA'ya pinlenmiştir.
- **`.env` yalnızca servis kullanıcısına açık** (`0640 cicd-<servis>:cicd`).

**Bilinen ödünleşim:** `deploy` kullanıcısı sunucuda geniş sudo yetkisine sahiptir (pipeline
`sudo bash -c` kullandığından). Bu yüzden `deploy` kullanıcısını yalnızca dağıtıma ayırın ve
SSH anahtarını (Secret) dar tutun. Ayrıntı: [`security-review.tr.md`](./security-review.tr.md).

---

## 16. Sorun giderme

| Ekranda görünen | Muhtemel neden / çözüm |
|---|---|
| `Permission denied (publickey)` | `deploy_key.pub` sunucuda `authorized_keys`'te değil veya yanlış kullanıcı |
| `sudo: a password is required` | Adım D.3 sudoers yapılmamış (`sudo OK` alınmamış) |
| `Host key verification failed` / `SSH_KNOWN_HOSTS tanimli degil` | `SSH_KNOWN_HOSTS` boş/yanlış → Adım D.5'i yapın |
| `invalid format` / libcrypto | Secret'a private key eksik yapıştırıldı (BEGIN/END dahil olmalı) |
| Deploy: "CI artifact commit != deploy commit" | O commit için CI yeşil değil → önce push + CI bekleyin, veya `build_from_source` seçin |
| Health fail — canlı etkilenmedi | Uygulama socket'te 200 dönmüyor: `/health` var mı? URL sabitlenmiş mi? (Bölüm 6.2–6.3) |
| CI kırmızı | Runner online mı? `SERVICES` yolları doğru mu? Runner'da `dotnet` sürümü uygun mu? |
| Deploy onay bekliyor | Onaylayıcı **farklı** hesapla girip Approve basmalı (self-review kapalıysa) |
| nginx health portu cevap vermiyor | `setup-host.sh`/`setup-remote-host.sh` çalıştı mı? Firewall portu açık mı? |

Sunucuda hızlı kontrol (SSH ile):

```bash
sudo systemctl status myapp-web-blue myapp-web-green   # servis durumu
sudo nginx -t                                           # nginx config testi
cat /etc/nginx/cicd/myapp-web.active                    # şu an aktif renk
sudo journalctl -u myapp-web-blue -n 50 --no-pager      # uygulama logu
```

---

## 17. Kurulum bitti — kontrol listesi

**Ortak:**
- [ ] Template → yeni repo; `templates/` içeriği **kökte** (`.github/`, `scripts/`)
- [ ] Kod: URL sabitlenmemiş + `/health` (veya `/`) 200 dönüyor
- [ ] `SERVICES` doğru formatta (5 alan, `|` ile)
- [ ] `production` environment: required reviewers + prevent self-review + yalnızca `main`
- [ ] En az bir kez **Continuous Integration** yeşil
- [ ] **Production Deploy** açıklama ile tetiklendi ve onaylandı
- [ ] `EF_PROJECT` tanımlı (DB projeleri), `APP_ENV` içinde bağlantı dizesi

**remote ek:**
- [ ] Sunucuda `deploy` kullanıcısı + `authorized_keys`
- [ ] `sudo OK` alındı (`NOPASSWD: ALL`)
- [ ] `rsync`, `curl`, `nginx` (+ .NET) sunucuda kurulu
- [ ] Variables: `DEPLOY_TARGET=remote`, `SSH_HOST`, `SSH_USER`, `RUNNER_LABEL=ubuntu-latest`, `SSH_KNOWN_HOSTS`
- [ ] Secret: `SSH_PRIVATE_KEY` (tam metin, BEGIN/END)
- [ ] `setup-remote-host.sh` bir kez çalıştı (nginx + systemd birimleri kuruldu)

**local ek:**
- [ ] Self-hosted runner online (yeşil)
- [ ] `DEPLOY_TARGET=local`, `RUNNER_LABEL=self-hosted`
- [ ] `setup-host.sh` bir kez çalıştı

Hepsi tik → kurulum **tamam.** Bundan sonra: kod yaz → push → CI yeşil → Production Deploy → onay.

---

## Yardımcı bağlantılar

- Blueprint reposu: <https://github.com/Dedmoo/dotnet-cicd-template>
- Tıkla-tıkla rehber: [`beginner-walkthrough.tr.md`](./beginner-walkthrough.tr.md)
- Referans tablolar: [`company-setup.tr.md`](./company-setup.tr.md)
- Derin playbook: [`dotnet-cicd-template.tr.md`](./dotnet-cicd-template.tr.md)
- Güvenlik incelemesi: [`security-review.tr.md`](./security-review.tr.md)
