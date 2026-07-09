#!/usr/bin/env bash
#
# CI/CD Blueprint - tek seferlik host kurulumu (blue-green / Unix socket)
# CI/CD Blueprint - one-time host setup (blue-green / Unix socket)
#
# Her servis icin olusturur / Creates per-service:
#   - Iki systemd birimi (blue/green) — Unix socket uzerinde dinler
#     Two systemd units (blue/green) — listening on Unix socket
#   - nginx upstream include (varsayilan: blue) + public-port server blogu
#     nginx upstream include (default: blue) + public-port server block
#
# Sifir kesinti nasil calisir / How zero-downtime works:
#   Deploy yeni surumu bos (idle) renge yazar, saglik kontrolundan gecince
#   nginx trafiklerini o renge ceviren graceful reload yapar. Eski renk
#   ayakta kalir; anlık rollback hedefidir.
#   Deploy writes the new version to the idle color, then — if health passes —
#   switches nginx to that color with a graceful reload. The old color stays up
#   as an instant rollback target.
#
# Gereksinimler / Requirements: systemd, nginx (kurulmazsa bu script kurar),
#                               dotnet, curl
#
# Kullanim / Usage (root):
#   sudo SERVICES="..." bash setup-host.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "root ile calistir / run as root: sudo SERVICES=... bash setup-host.sh"
  exit 1
fi

DOTNET_PATH="${DOTNET_PATH:-/usr/bin/dotnet}"
ASPNETCORE_ENV="${ASPNETCORE_ENV:-Production}"
# nginx conf.d dizini (dist'e gore degisebilir)
# nginx conf.d directory (may vary by distro)
NGINX_CONFD="${NGINX_CONFD:-/etc/nginx/conf.d}"
# blueprint upstream include dosyalari buraya yazilir; pipeline.sh bunu okur/yazar
# blueprint upstream include files live here; pipeline.sh reads/writes this
CICD_DIR="/etc/nginx/cicd"

# --- dotnet kontrol / dotnet check ---
if ! command -v "$DOTNET_PATH" >/dev/null 2>&1 && [ ! -x "$DOTNET_PATH" ]; then
  echo "HATA / ERROR: dotnet bulunamadi / not found: $DOTNET_PATH"
  echo "  Kurmak icin / To install: https://learn.microsoft.com/dotnet/core/install/linux"
  exit 1
fi

# --- nginx kurulum / nginx install ---
if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx bulunamadi, kuruluyor / nginx not found, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y nginx
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx
  else
    echo "HATA / ERROR: nginx bulunamadi ve paket yoneticisi taninamadi."
    echo "  Manuel kurun / Install manually: apt install nginx  OR  yum install nginx"
    exit 1
  fi
fi

# --- nginx kullanicisini tespit et / detect nginx service user ---
if id www-data >/dev/null 2>&1; then
  NGINX_USER="www-data"   # Debian/Ubuntu
elif id nginx >/dev/null 2>&1; then
  NGINX_USER="nginx"      # RHEL/CentOS/Fedora
else
  echo "HATA / ERROR: nginx servis kullanicisi bulunamadi (beklenen: www-data veya nginx)"
  exit 1
fi
echo "nginx kullanicisi / user: $NGINX_USER"

# --- cicd grubu olustur / create cicd group ---
# nginx ve .NET servisleri bu grup uzerinden socket'e erisir.
# nginx and .NET services share socket access via this group.
if ! getent group cicd >/dev/null 2>&1; then
  groupadd --system cicd
  echo "cicd grubu olusturuldu / group created: cicd"
fi

usermod -aG cicd "$NGINX_USER"
echo "nginx kullanicisi cicd grubuna eklendi / nginx user added to cicd group: $NGINX_USER"

# --- dizinler / directories ---
mkdir -p "$CICD_DIR"
mkdir -p "$NGINX_CONFD"

# --- servisler / services ---
printf '%s\n' "${SERVICES:?SERVICES ortam degiskeni tanimli degil / SERVICES env not set}" \
  | grep -vE '^\s*(#.*)?$' \
  | while IFS= read -r line; do
      csproj="$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      dd="$(printf '%s' "$line"     | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      svc="$(printf '%s' "$line"    | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      hurl="$(printf '%s' "$line"   | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

      # health_url formatindan portu cikart: http://IP:PORT/path -> PORT
      # Extract port from health_url: http://IP:PORT/path -> PORT
      port="$(printf '%s' "$hurl" | sed -E 's#.*:([0-9]+)(/.*)?$#\1#')"
      dll="$(basename "$csproj" .csproj).dll"

      echo "Servis kuruluyor / setting up service: $svc (port $port)"

      # --- Dusuk yetkili servis kullanicisi / low-privilege service account ---
      # Uygulama root yerine login'siz, sistem kullanicisiyla calisir (en az yetki).
      # Birincil grup cicd: socket'e (0660 svc_user:cicd) ve .env'e (0640) erisim.
      # The app runs as a login-less system user instead of root (least privilege).
      # Primary group cicd: access to the socket (0660 svc_user:cicd) and .env (0640).
      svc_user="cicd-${svc}"
      if ! id "$svc_user" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin --gid cicd "$svc_user"
        echo "  servis kullanicisi olusturuldu / service user created: $svc_user"
      fi

      # Her renk icin systemd birimi / systemd unit for each color
      for color in blue green; do
        unit_name="${svc}-${color}"
        unit_dir="${dd}-${color}"
        sock_path="/run/cicd/${svc}-${color}.sock"

        cat > "/etc/systemd/system/${unit_name}.service" <<UNIT
[Unit]
Description=${svc} .NET service — ${color} (CI/CD Blueprint blue-green)
After=network.target

[Service]
WorkingDirectory=${unit_dir}
ExecStart=${DOTNET_PATH} ${unit_dir}/${dll} --urls http://unix:${sock_path}
Restart=on-failure
RestartSec=5
# Dusuk yetkili kullanici: uygulama root DEGIL, ozel servis hesabiyla calisir.
# Low-privilege user: the app runs as a dedicated account, NOT root.
User=${svc_user}
# Grup ve UMask: socket 0660 olarak olusturulur (cicd grubu erisebilir).
# Group and UMask: socket is created as 0660 (accessible by cicd group).
Group=cicd
UMask=0007
# systemd sertlestirme / systemd hardening:
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
RestrictSUIDSGID=yes
# RuntimeDirectory: her start/stop dongusu icin /run/cicd/ olusturur.
# RuntimeDirectoryPreserve: diger renk calisirken dizin silinmez.
# RuntimeDirectory: creates /run/cicd/ on each start/stop cycle.
# RuntimeDirectoryPreserve: keeps directory alive while the other color runs.
RuntimeDirectory=cicd
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
Environment=ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENV}
Environment=DOTNET_USE_POLLING_FILE_WATCHER=1
# Not: svc_user'in home'u yoktur; DataProtection anahtarlarini kalici saklamak
# gerekirse KeyDir tanimlayip ReadWritePaths ekleyin (ornek asagida yorumda).
# Note: svc_user has no home; to persist DataProtection keys define a KeyDir and
# add ReadWritePaths (see the commented example below).
# ReadWritePaths=${unit_dir}/keys
# Gizli ortam degiskenleri — deploy'da yazilir; yoksa yok sayilir
# Secret env vars — written at deploy; ignored if absent
EnvironmentFile=-${unit_dir}/.env

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload
        systemctl enable "$unit_name"
        echo "  systemd birimi / unit: ${unit_name} — socket: ${sock_path} — user: ${svc_user}"
      done

      # --- nginx upstream include (varsayilan: blue) ---
      # pipeline.sh cmd_switch bu dosyayi yeniden yazar + nginx reload yapar.
      # pipeline.sh cmd_switch rewrites this file + triggers nginx reload.
      cat > "${CICD_DIR}/${svc}-upstream.conf" <<NGINX
upstream cicd_${svc} {
    server unix:/run/cicd/${svc}-blue.sock;
    keepalive 32;
}
NGINX

      # --- aktif renk durum dosyasi (kesin kaynak) / active-color state file ---
      # pipeline.sh aktif rengi bu dosyadan okur; upstream metnini grep'lemez.
      # Baslangic degeri upstream varsayilaniyla (blue) tutarli olmali.
      # pipeline.sh reads the active color from this file; it does not grep the
      # upstream text. Initial value must match the upstream default (blue).
      printf 'blue\n' > "${CICD_DIR}/${svc}.active"
      chmod 644 "${CICD_DIR}/${svc}.active"

      # --- nginx server blogu / server block ---
      # upstream include bu dosyadan cagrilir; pipeline sadece upstream include'i degistirir.
      # upstream include is called from this file; pipeline only rewrites the upstream include.
      cat > "${NGINX_CONFD}/cicd-${svc}.conf" <<NGINX
include ${CICD_DIR}/${svc}-upstream.conf;

server {
    listen ${port};

    location / {
        proxy_pass         http://cicd_${svc};
        proxy_http_version 1.1;
        # Keepalive icin Connection basi temizle / clear Connection header for keepalive
        proxy_set_header   Connection        "";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINX

      echo "  nginx: port ${port} -> cicd_${svc} (varsayilan/default: ${svc}-blue.sock)"
    done

# --- nginx baslat / start nginx ---
echo "nginx yapilandirmasi test ediliyor / testing nginx configuration..."
if nginx -t 2>&1; then
  systemctl enable --now nginx
  systemctl restart nginx
  echo "nginx baslatildi / nginx started: OK"
else
  echo "HATA / ERROR: nginx yapilandirmasi gecersiz. Yukaridaki ciktiya bakin."
  exit 1
fi

echo ""
echo "tamam / done."
echo "  Servisler ilk basarili deploy'dan sonra otomatik baslar."
echo "  Services auto-start after the first successful deploy."
