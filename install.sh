#!/usr/bin/env bash
# install.sh - Multi-VPS reverse proxy gateway bootstrap (gost + TLS + iptables allowlist)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root." >&2
    exit 1
fi

GOST_HOME="/etc/gost"
CERT_DIR="${GOST_HOME}/certs"
PORT="${1:-8443}"
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
REPO_RAW="https://raw.githubusercontent.com/mehedimhr/gost-gateway/main"

echo "[*] Preparing directories"
mkdir -p "${CERT_DIR}"

echo "[*] Installing required packages (non-interactive)"
export DEBIAN_FRONTEND=noninteractive
REQUIRED_PKGS=(curl wget tar openssl iptables cron zip unzip sed grep)
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends "${MISSING[@]}"
fi
systemctl enable --now cron >/dev/null 2>&1 || true

echo "[*] Checking for Tailscale interface"
if ip link show tailscale0 >/dev/null 2>&1; then
    echo "    tailscale0 present - leaving interface untouched"
else
    echo "    tailscale0 not found - continuing without it"
fi

echo "[*] Writing port configuration"
echo "${PORT}" > "${GOST_HOME}/config.port"

echo "[*] Installing gost binary if missing"
if ! command -v gost >/dev/null 2>&1; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64) GOST_ARCH="amd64" ;;
        aarch64) GOST_ARCH="arm64" ;;
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
    esac
    GOST_VERSION="$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest | grep -oP '"tag_name":\s*"v\K[0-9.]+' | head -n1)"
    GOST_VERSION="${GOST_VERSION:-3.2.6}"
    TMP_TGZ="$(mktemp)"
    curl -fsSL -o "${TMP_TGZ}" \
        "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${GOST_ARCH}.tar.gz"
    tar -xzf "${TMP_TGZ}" -C /usr/local/bin gost
    chmod +x "${BIN_DIR}/gost"
    rm -f "${TMP_TGZ}"
else
    echo "    gost already installed at $(command -v gost)"
fi

echo "[*] Generating TLS keypair if missing"
if [[ ! -s "${CERT_DIR}/cert.pem" || ! -s "${CERT_DIR}/key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
        -days 3650 -subj "/CN=gost-gateway"
fi
chmod 600 "${CERT_DIR}/key.pem"

echo "[*] Deploying allowed_ips.txt (kept if already present)"
if [[ ! -f "${GOST_HOME}/allowed_ips.txt" ]]; then
    curl -fsSL "${REPO_RAW}/allowed_ips.txt" -o "${GOST_HOME}/allowed_ips.txt"
fi

echo "[*] Installing firewall sync script"
curl -fsSL "${REPO_RAW}/sync_fw.sh" -o "${SBIN_DIR}/sync_fw.sh"
chmod 0755 "${SBIN_DIR}/sync_fw.sh"

echo "[*] Installing gost launch wrapper"
cat > "${SBIN_DIR}/gost-launch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
GOST_HOME="/etc/gost"
CERT_DIR="${GOST_HOME}/certs"

# Regenerate cert if missing, corrupted, or zeroed - must exist before daemon starts
if [[ ! -s "${CERT_DIR}/cert.pem" || ! -s "${CERT_DIR}/key.pem" ]] \
   || ! openssl x509 -in "${CERT_DIR}/cert.pem" -noout >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
        -days 3650 -subj "/CN=gost-gateway"
    chmod 600 "${CERT_DIR}/key.pem"
fi

[[ "${1:-}" == "--check" ]] && exit 0

PORT="$(cat "${GOST_HOME}/config.port")"
exec /usr/local/bin/gost -L "relay+tls://:${PORT}?cert=${CERT_DIR}/cert.pem&key=${CERT_DIR}/key.pem"
EOF
chmod 0755 "${SBIN_DIR}/gost-launch.sh"

echo "[*] Installing systemd unit"
curl -fsSL "${REPO_RAW}/gost-proxy.service" -o /etc/systemd/system/gost-proxy.service
systemctl daemon-reload
systemctl enable --now gost-proxy.service

echo "[*] Installing cron sync (every 60s + @reboot)"
CRON_FILE="/etc/cron.d/gost-fw-sync"
cat > "${CRON_FILE}" <<EOF
* * * * * root ${SBIN_DIR}/sync_fw.sh >/var/log/gost-fw-sync.log 2>&1
@reboot root ${SBIN_DIR}/sync_fw.sh >/var/log/gost-fw-sync.log 2>&1
EOF
chmod 0644 "${CRON_FILE}"

echo "[*] Running initial firewall sync"
"${SBIN_DIR}/sync_fw.sh"

echo "[+] Done. Port=${PORT}. Edit ${GOST_HOME}/allowed_ips.txt to manage access (applies within 60s)."
