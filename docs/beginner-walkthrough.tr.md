# Hiç Bilmeyenler İçin — Adım Adım Kurulum

Bu dosyayı, **CI/CD, SSH, GitHub Actions** gibi kelimeleri duymuş ama pratikte hiç kurmamış kişiler için yazdık.

- Teknik öğrenmeniz gerekmez.
- YML dosyası açmayın / düzenlemeyin.
- Sadece aşağıdaki numaraları sırayla uygulayın.
- Takıldığınız yerde kırmızı hata yazısını okuyun; çoğu zaman “ne unuttunuz” yazılır.

Daha kısa teknik özet (Variables tablosu vb.): [`company-setup.tr.md`](./company-setup.tr.md)  
English: [`beginner-walkthrough.en.md`](./beginner-walkthrough.en.md)

---

## Bu sistem ne yapıyor? (30 saniye)

Amaç şudur: **yeni sürümü canlıya almak.** Siteyi / programı kullanan kişi sayfada gezerken veya F5 yaptığında güncellemeyi görür; “herkese duyuru yapıp uygulamayı elle kapatın / resetleyin” diye bir süreç olmaz.

Kısaca akış:

1. Kod GitHub’a yazılınca otomatik **derlenir ve test edilir**.
2. Yetkili biri “canlıya al” isteğini **onaylar**.
3. Onaydan sonra yeni sürüm **uzak sunucunun boş kanalına** yazılır; sağlık kontrolü geçince nginx trafiği **sessizce** yeni kanala çevirir — kullanıcılar hiçbir şey fark etmez, bir sonraki isteklerinde güncel hâli alırlar. Buna "blue-green" dağıtım denir.
4. Veritabanı kullanan projelerde deploy öncesi **EF Core migration** otomatik çalışır (`EF_PROJECT` variable'ı ile).
5. Yeni sürüm sağlık kontrolünden geçemezse geçiş **hiç yapılmaz** — canlı kullanıcılar eski sürümü görmeye kesintisiz devam eder.

Sizin işiniz: ayarları bir kez doldurmak. Sonrası: kod yaz → onay → canlı güncellenir.

> Teknik not (merak eden için): Sunucuda iki kanal (mavi/yeşil) vardır; biri her zaman canlıdır. Yeni sürüm boş kanala kurulur, sağlıklı çalıştığı onaylanınca nginx trafiği buna yönlendirir. Eski kanal açık kalır; sorun olursa anlık geri dönüş yapılır.

---

## İki yol var — birini seçin

| Seçenek | Anlamı | Kim yapar? |
|---|---|---|
| **A — Aynı bilgisayar** | Kod çalışan makine = sunucu | Self-hosted runner kullananlar |
| **B — Uzak sunucu** | Uygulama başka bir Linux sunucuda | Çoğu şirket / canlı deneme — **bu rehber B’yi anlatır** |

A için sonra [`company-setup.tr.md`](./company-setup.tr.md) “Yerel” kısmına bakın. Burada **B (uzak)** adım adım anlatılır.

---

## İhtiyacınız olanlar (başlamadan)

- [ ] Bir **GitHub hesabı** (ücretsiz olabilir)
- [ ] Template’i kendi hesabınıza kopyalama izni
- [ ] Bir **Linux sunucu** (IP adresi / hostname, SSH ile girilebiliyor)
- [ ] Sunucuya **yönetici (root/sudo)** girebilme
- [ ] Kendi bilgisayarınızda terminal (Windows: PowerShell veya WSL; Mac/Linux: Terminal)
- [ ] .NET uygulamanızın kodu (veya deneme projesi)

Anlamadığınız terimler:

| Kelime | Basit anlamı |
|---|---|
| **Repo** | GitHub’daki proje klasörü |
| **Variable** | Herkese (repo yetkililerine) görünen ayar metni |
| **Secret** | Gizli ayar (şifre/anahtar); loglarda görünmez |
| **Environment** | “Canlıya çıkmadan önce onay iste” kutusu |
| **Runner** | GitHub’ın sizin için komut çalıştırdığı bilgisayar |
| **SSH** | Sunucuya şifresiz / anahtarla uzak bağlantı |
| **Deploy** | Canlıya alma / kullanıcılara yeni sürümü yayınlama |

---

## Bölüm 0 — Anahtar üretin (kendi bilgisayarınızda)

Bu anahtar, GitHub’ın sunucunuza “ben yetkiliyim” demesini sağlar. **Şifre sorulmaz** çünkü anahtar kullanılır.

1. Terminal açın.
2. Şunu yapıştırıp Enter’a basın:

```bash
ssh-keygen -t ed25519 -C "deploy" -N "" -f deploy_key
```

3. Aynı klasörde iki dosya oluşur:
   - `deploy_key` → **gizli**. Bunu GitHub’a Secret olarak yapıştıracağız.
   - `deploy_key.pub` → **açık**. Bunu sunucuya koyacağız.

4. `deploy_key` içeriğini görmek için:

```bash
# Linux / Mac / WSL
cat deploy_key

# Windows PowerShell
Get-Content deploy_key
```

Ekranda `-----BEGIN OPENSSH PRIVATE KEY-----` ile başlayan uzun metin görünmeli. Bunu bir yere **geçici** saklayın (Not Defteri). Bitince Not Defteri’nden silin.

---

## Bölüm 1 — GitHub’da proje oluşturun

1. Tarayıcıda açın: https://github.com/Dedmoo/dotnet-cicd-template  
2. Yeşil **Use this template** → **Create a new repository**  
3. Repo adı verin (ör. `sirketim-uygulama`), **Create**  
4. Repo açıldıktan sonra `templates` klasörünü görün. İçindeki her şeyi **kök klasöre taşıyın**:
   - `.github` klasörü kökte olmalı  
   - `scripts` klasörü kökte olmalı  
5. Kendi .NET kodunuzu da aynı repo köküne koyun (`src/...` gibi).  
6. Değişiklikleri `main` dalına push edin (GitHub web arayüzü veya bilgisayarınızdan).

Kontrol: Repo kökünde `.github/workflows/production-deploy.yml` dosyasını görebiliyor musunuz? Evet → devam.

---

## Bölüm 2 — Sunucuyu hazırlayın (Linux, bir kez)

Sunucuya SSH ile yönetici olarak girin (IP’nizi yazın):

```bash
ssh root@SUNUCU_IP
```

veya sudo’lu kendi kullanıcınızla.

### 2.1 Kullanıcı oluşturun

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

### 2.2 Açık anahtarı sunucuya koyun

Kendi bilgisayarınızda `deploy_key.pub` içeriğini kopyalayın:

```bash
cat deploy_key.pub
```

Sunucuda (aşağıdaki `YAPISTIR` yerine tek satırlık `.pub` içeriğini koyun):

```bash
echo "YAPISTIR" | sudo tee /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
```

### 2.3 Şifresiz yönetici izni (çok önemli)

Bunlar olmadan canlı deploy **kırmızı** düşer:

```bash
echo 'deploy ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/deploy
sudo chmod 440 /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
sudo -u deploy sudo -n true && echo "sudo OK"
```

Ekranda `sudo OK` görmelisiniz. Görmüyorsanız durun; bir sonraki adıma geçmeyin.

### 2.4 Gerekli programlar

```bash
sudo apt-get update
sudo apt-get install -y rsync curl nginx
```

Ayrıca sunucuda uygulamanızın ihtiyaç duyduğu **.NET** sürümü kurulu olmalı (şirketinizdeki sürüm neyse — örn. .NET 8).

> Not: `nginx` yüklü değilse kurulum scripti (`setup-remote-host.sh`) otomatik kurar; yine de önceden yüklü olursa hata olmaz.

### 2.5 Host kimliğini alın (`SSH_KNOWN_HOSTS`)

**Kendi bilgisayarınızda** (sunucudan çıkmışken):

```bash
ssh-keyscan -p 22 SUNUCU_IP
```

Çıkan **tüm satırları** kopyalayın. Bunu birazdan GitHub Variable olarak yapıştıracağız.

---

## Bölüm 3 — GitHub ayarları (tıklaya tıklaya)

Repoda: üstte **Settings** (ayarlar).

### 3.1 Variables (görünen ayarlar)

Yol: **Settings → Secrets and variables → Actions → Variables** sekmesi → **New repository variable**

Şunları **tek tek** ekleyin:

| Name (ad) | Value (değer) — örneği kendi bilgilerinizle değiştirin |
|---|---|
| `DEPLOY_TARGET` | `remote` |
| `SSH_HOST` | Sunucu IP veya domain (örn. `203.0.113.10`) |
| `SSH_USER` | `deploy` |
| `SSH_PORT` | `22` (port farklıysa onu yazın) |
| `RUNNER_LABEL` | `ubuntu-latest` |
| `SSH_KNOWN_HOSTS` | Bölüm 2.5’teki `ssh-keyscan` çıktısının tamamı |
| `SERVICES` | Aşağıdaki tek satırı **kendi yollarınıza** uyarlayın |
| `EF_PROJECT` | Migration içeren proje, örn. `src/Infrastructure/Infrastructure.csproj` |
| `EF_STARTUP_PROJECT` | (Opsiyonel) Startup proje; boşsa `SERVICES` ilk csproj kullanılır |

`SERVICES` örneği (tek uygulama):

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SUNUCU_IP:5001
```

Anlamı (öğrenmenize gerek yok, dolu kalsın):

- `web` = kısa ad  
- `src/Web/Web.csproj` = derlenecek proje dosyası (sizin yolda neyse onu yazın)  
- `/opt/myapp-web` = sunucuda kurulum klasörü  
- `myapp-web` = servis adı  
- `http://SUNUCU_IP:5001` = nginx'in public portudur (health path eklenebilir: `http://SUNUCU_IP:5001/health`)  

> Pipeline sağlık kontrolünü **socket üzerinden** yapar; IP kısmını yoksayar. Port ve path önemlidir.

Çok satırlı `SERVICES`: Variable kutusuna Enter ile ikinci satır ekleyebilirsiniz.

### 3.2 Secrets (gizli ayarlar)

Yol: **Settings → Secrets and variables → Actions → Secrets** sekmesi → **New repository secret**

| Name | Value |
|---|---|
| `SSH_PRIVATE_KEY` | Bölüm 0’daki `deploy_key` dosyasının **tüm** metni (`BEGIN` … `END` dahil) |

Veritabanı kullanan projeler için (zorunlu):

| Name | Value |
|---|---|
| `APP_ENV` | Bağlantı dizesi, örn. `ConnectionStrings__DefaultConnection=Server=DB_IP,1433;User Id=...;Password=...;TrustServerCertificate=true` |

API anahtarı vb. diğer gizli ayarları da aynı secret içine satır satır ekleyebilirsiniz.

### 3.3 Production onayı kutusu

Yol: **Settings → Environments → New environment**

1. Adı **tam olarak** yazın: `production`  
2. **Configure environment**  
3. **Required reviewers** → en az bir kişi seçin (kendiniz + bir arkadaş olabilir)  
4. **Prevent self-review** işaretli olsun (mümkünse)  
5. Deployment branches → **Selected branches** → sadece `main`  
6. Save

Bu olmadan “Production Deploy” onaysız / beklenmedik şekilde davranabilir.

---

## Bölüm 4 — Sunucuya bir kez “kurulum scripti”

Kendi bilgisayarınızda, repo kökünde `scripts` klasörü varken (ve `deploy_key` aynı klasördeyken):

```bash
SSH_HOST=SUNUCU_IP \
SSH_USER=deploy \
SSH_PORT=22 \
SSH_PRIVATE_KEY="$(cat deploy_key)" \
SERVICES="web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://SUNUCU_IP:5001" \
bash scripts/setup-remote-host.sh
```

Windows PowerShell’de `bash` yoksa WSL / Git Bash kullanın.

Bitince hata yoksa sunucuda nginx ve systemd birimleri oluşmuş demektir. Uygulama henüz boş olabilir; ilk deploy doldurur.

---

## Bölüm 5 — İlk otomatik derleme (CI)

1. `main` dalına herhangi küçük bir değişiklik push edin (veya zaten push’unuz varsa bekleyin).  
2. GitHub’da repo → **Actions** sekmesi.  
3. **Continuous Integration** adlı çalışmanın yeşil tik almasını bekleyin.  

Kırmızıysa: Actions içindeki kırmızı adıma tıklayıp log okuyun (çoğu zaman yanlış `SERVICES` yolu veya eksik .NET).

---

## Bölüm 6 — Canlıya alma (Deploy)

1. **Actions** → solda **Production Deploy**  
2. **Run workflow**  
3. Açıklama yazın (zorunlu), örn. `ilk canlı deneme`  
4. Source: **`ci_artifact`** kalsın (ilk kez artifact yoksa bir kez `build_from_source` seçin)  
5. **Run workflow**  

Sonra:

1. Çalışma açılır → önce **prepare** yeşile döner (özet yazar).  
2. Onaylayan kişi Summary / onay ekranına bakar → **Approve**.  
3. Deploy biter → kırmızıysa nginx geçişi yapılmamış demektir; canlı etkilenmedi. Sorunu giderin, yeniden tetikleyin.

Deploy sırasında (onaydan sonra): önce veritabanı migration'ı çalışır, sonra yeni sürüm idle renge yazılır.

Başarı: sunucuda uygulamanız `health_url` adresinden cevap verir.

---

## Bir şey kırılırsa (kısa sözlük)

| Ekranda görünen | Muhtemel unutulan |
|---|---|
| `Permission denied (publickey)` | `deploy_key.pub` sunucuda yok veya yanlış kullanıcı |
| `sudo: a password is required` | Bölüm 2.3 sudoers yapılmamış |
| `Host key verification failed` | `SSH_KNOWN_HOSTS` boş/yanlış |
| `invalid format` / libcrypto | Secret’a anahtar eksik yapıştırıldı (BEGIN/END) |
| Health fail ama bağlandınız | nginx kurulmamış veya `setup-remote-host.sh` çalışmamış | Önce kurulum scriptini çalıştırın; sonra deploy tetikleyin. |
| Artifact bulunamadı | Önce CI yeşil olmalı; veya bir kez `build_from_source` |
| Migration hatası | `EF_PROJECT` yolu doğru mu? `APP_ENV` içinde bağlantı dizesi var mı? Runner DB'ye erişebiliyor mu? |

Daha uzun tablo: repo kökündeki [`README.md`](../README.md) “Sorun giderme” bölümü.

---

## Bitince kontrol listesi

- [ ] `deploy_key` / `.pub` üretildi  
- [ ] Sunucuda `deploy` + authorized_keys  
- [ ] `sudo OK` çıktısı alındı  
- [ ] GitHub Variables: `DEPLOY_TARGET`, `SSH_*`, `RUNNER_LABEL`, `SERVICES`, `SSH_KNOWN_HOSTS`, `EF_PROJECT`
- [ ] Secret: `SSH_PRIVATE_KEY` + `APP_ENV` (DB bağlantı dizesi)
- [ ] Environment: `production` + reviewer  
- [ ] `setup-remote-host.sh` çalıştı (nginx + systemd birimleri kuruldu)  
- [ ] Continuous Integration yeşil  
- [ ] Production Deploy onaylandı ve başarılı  

Hepsi tikliyse: **kurulum bitti**. Bundan sonra günlük iş: kod yaz → push → CI yeşil → Production Deploy → onay.
