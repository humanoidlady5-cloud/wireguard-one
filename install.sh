#!/usr/bin/env bash
#
# WireGuard One — One-command WireGuard VPN installer
# Supports: Ubuntu 22.04/24.04, Debian 12
# Usage:    sudo ./install.sh
#
set -euo pipefail

readonly VERSION="1.0.0"
readonly WG_DIR="/etc/wireguard"
readonly IFACE="wg0"
readonly DEFAULT_PORT="51820"
readonly DEFAULT_SUBNET="10.66.66"
readonly CONFIG_DIR="/root/wireguard-clients"
readonly BIN_HELPER="/usr/local/bin/wg-add-client"

if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
    B='\033[0;34m'; C='\033[0;36m'; BOLD='\033[1m'; N='\033[0m'
else
    R=''; G=''; Y=''; B=''; C=''; BOLD=''; N=''
fi

log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*" >&2; }
info() { echo -e "${B}[i]${N} $*"; }
die()  { err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root. Use: sudo $0"

echo
echo "================================================================"
echo "  WireGuard One - v${VERSION}"
echo "  One-command WireGuard VPN for Ubuntu & Debian"
echo "================================================================"
echo

if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"')
    OS_PRETTY=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
    case "$OS_ID" in
        ubuntu|debian) log "Detected: ${OS_PRETTY}" ;;
        *) warn "Untested OS: ${OS_PRETTY}. Proceeding anyway..." ;;
    esac
fi

EGRESS_IF=$(ip -4 route show default | awk '/default/ {print $5; exit}' || true)
[[ -n "${EGRESS_IF:-}" ]] || die "Could not detect default network interface."
log "Egress interface: ${EGRESS_IF}"

echo
echo "Configuration (press Enter to accept defaults)"
echo

read -rp "UDP port for WireGuard [${DEFAULT_PORT}]: " WG_PORT
WG_PORT="${WG_PORT:-$DEFAULT_PORT}"
if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
    die "Invalid port: $WG_PORT"
fi

read -rp "Internal subnet (first 3 octets) [${DEFAULT_SUBNET}]: " SUBNET
SUBNET="${SUBNET:-$DEFAULT_SUBNET}"
if ! [[ "$SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid subnet: $SUBNET"
fi

SERVER_IP="${SUBNET}.1/24"
CLIENT_SUBNET="${SUBNET}.0/24"
DNS="1.1.1.1, 1.0.0.1"

log "Detecting public IP..."
PUB_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    try=$(curl -s --max-time 5 "$url" 2>/dev/null || true)
    if [[ "$try" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PUB_IP="$try"
        break
    fi
done

if [[ -z "$PUB_IP" ]]; then
    warn "Could not auto-detect public IP."
    read -rp "Enter this server's public IP manually: " PUB_IP
    if ! [[ "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid IP."
    fi
fi
log "Public IP: ${PUB_IP}"

echo
echo "Summary"
echo "  Interface:  ${IFACE}"
echo "  Port:       ${WG_PORT}/udp"
echo "  Subnet:     ${CLIENT_SUBNET}"
echo "  Server IP:  ${SERVER_IP}"
echo "  Endpoint:   ${PUB_IP}:${WG_PORT}"
echo
read -rp "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo
log "Installing packages (this may take ~30 seconds)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq wireguard wireguard-tools iptables qrencode curl >/dev/null
log "Packages installed."

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW is active - allowing UDP ${WG_PORT}..."
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
fi

log "Preparing ${WG_DIR}..."
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
umask 077

log "Generating server keys..."
wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
wg genpsk > "$WG_DIR/psk.key"
chmod 600 "$WG_DIR"/server.key "$WG_DIR"/server.pub "$WG_DIR"/psk.key

SERVER_PRIV=$(cat "$WG_DIR/server.key")
PSK=$(cat "$WG_DIR/psk.key")

if [[ -f "$WG_DIR/${IFACE}.conf" ]]; then
    BACKUP="$WG_DIR/${IFACE}.conf.bak.$(date +%s)"
    cp "$WG_DIR/${IFACE}.conf" "$BACKUP"
    warn "Existing config backed up to ${BACKUP}"
fi

log "Writing server config..."
cat > "$WG_DIR/${IFACE}.conf" <<EOF
[Interface]
Address    = ${SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU        = 1280

PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = iptables -A FORWARD -i %i -j ACCEPT
PostUp   = iptables -A FORWARD -o %i -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -o ${EGRESS_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${EGRESS_IF} -j MASQUERADE
EOF
chmod 600 "$WG_DIR/${IFACE}.conf"

log "Installing helper: wg-add-client"
cat > "$BIN_HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root." >&2; exit 1; }

WG_DIR="/etc/wireguard"
IFACE="wg0"
CONFIG_DIR="/root/wireguard-clients"

[[ -f "$WG_DIR/server.pub" ]] || { echo "WireGuard not configured. Run install.sh first." >&2; exit 1; }
[[ -f "$WG_DIR/${IFACE}.conf" ]] || { echo "Missing server config." >&2; exit 1; }

SERVER_PUB=$(cat "$WG_DIR/server.pub")
PSK=$(cat "$WG_DIR/psk.key")

SERVER_ADDR=$(grep -m1 '^Address' "$WG_DIR/${IFACE}.conf" | awk '{print $3}' | cut -d',' -f1)
SUBNET=$(echo "$SERVER_ADDR" | cut -d'/' -f1 | cut -d'.' -f1-3)
[[ -n "$SUBNET" ]] || { echo "Could not parse subnet." >&2; exit 1; }

PORT=$(grep -m1 '^ListenPort' "$WG_DIR/${IFACE}.conf" | awk '{print $3}')
[[ -n "$PORT" ]] || { echo "Could not parse port." >&2; exit 1; }

PUB_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me"; do
    try=$(curl -s --max-time 5 "$url" 2>/dev/null || true)
    if [[ "$try" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PUB_IP="$try"
        break
    fi
done
[[ -n "$PUB_IP" ]] || { echo "Could not detect public IP." >&2; exit 1; }

NAME="${1:-client$(date +%s)}"
[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid name." >&2; exit 1; }

if [[ -f "$CONFIG_DIR/${NAME}.conf" ]]; then
    echo "Client '${NAME}' already exists." >&2
    exit 1
fi

USED=$(grep -h '^AllowedIPs' "$WG_DIR/${IFACE}.conf" 2>/dev/null | grep -oE '\.[0-9]+/32' | tr -d './32' || true)

NEXT=""
for i in $(seq 2 254); do
    if ! echo "$USED" | grep -qx "$i" 2>/dev/null; then
        NEXT="$i"
        break
    fi
done
[[ -n "$NEXT" ]] || { echo "No free IPs left." >&2; exit 1; }

CLIENT_IP="${SUBNET}.${NEXT}/32"

echo "[+] Creating client: ${NAME} (${CLIENT_IP})"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

wg genkey | tee "$WG_DIR/${NAME}.key" | wg pubkey > "$WG_DIR/${NAME}.pub"
chmod 600 "$WG_DIR/${NAME}.key" "$WG_DIR/${NAME}.pub"
CLIENT_PRIV=$(cat "$WG_DIR/${NAME}.key")
CLIENT_PUB=$(cat "$WG_DIR/${NAME}.pub")

if ! grep -q "$CLIENT_PUB" "$WG_DIR/${IFACE}.conf" 2>/dev/null; then
    cat >> "$WG_DIR/${IFACE}.conf" <<PEER_EOF

[Peer]
# ${NAME}
PublicKey    = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs   = ${CLIENT_IP}
PEER_EOF
fi

CLIENT_CONF="$CONFIG_DIR/${NAME}.conf"
cat > "$CLIENT_CONF" <<CONF_EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address    = ${CLIENT_IP}
DNS        = 1.1.1.1, 1.0.0.1
MTU        = 1280

[Peer]
PublicKey    = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint     = ${PUB_IP}:${PORT}
AllowedIPs   = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF_EOF
chmod 600 "$CLIENT_CONF"

wg set "$IFACE" peer "$CLIENT_PUB" preshared-key "$WG_DIR/psk.key" allowed-ips "$CLIENT_IP" 2>/dev/null \
    || systemctl restart "wg-quick@${IFACE}" 2>/dev/null \
    || true

echo "[+] Client config: $CLIENT_CONF"
echo
cat "$CLIENT_CONF"
echo
if command -v qrencode >/dev/null 2>&1; then
    echo "QR code:"
    qrencode -t ansiutf8 -r "$CLIENT_CONF"
fi
echo
HELPER_EOF

chmod 755 "$BIN_HELPER"

log "Enabling WireGuard service..."
systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${IFACE}"

sleep 2
if ! systemctl is-active --quiet "wg-quick@${IFACE}"; then
    err "Service failed to start. Logs:"
    journalctl -u "wg-quick@${IFACE}" -n 30 --no-pager
    exit 1
fi
log "Service is running."

log "Creating first client (phone)..."
"$BIN_HELPER" phone >/dev/null 2>&1 || warn "Could not auto-create first client. Run 'sudo wg-add-client phone' manually."

echo
echo "================================================================"
echo "  WireGuard One is UP"
echo "================================================================"
echo
echo "  Endpoint:   ${PUB_IP}:${WG_PORT}/udp"
echo "  Interface:  ${IFACE}"
echo "  Server IP:  ${SERVER_IP}"
echo
echo "!! ACTION REQUIRED: Open UDP port ${WG_PORT} in your VPS firewall"
echo
echo "  AWS EC2:      Security Groups -> Inbound -> UDP ${WG_PORT}"
echo "  Google Cloud: VPC -> Firewall Rules -> Ingress -> UDP ${WG_PORT}"
echo "  DigitalOcean: Usually open by default"
echo "  Linode:       Usually open by default"
echo "  Vultr:        Usually open by default"
echo "  Hetzner:      Cloud Firewall -> allow UDP ${WG_PORT}"
echo
echo "Add more devices:"
echo "  sudo wg-add-client laptop"
echo "  sudo wg-add-client tablet"
echo
echo "Client configs: ${CONFIG_DIR}/"
echo "Server config:  ${WG_DIR}/${IFACE}.conf"
echo

CLIENT_CONF="$CONFIG_DIR/phone.conf"
if [[ -f "$CLIENT_CONF" ]]; then
    echo "Scan with the WireGuard mobile app:"
    echo
    qrencode -t ansiutf8 -r "$CLIENT_CONF" 2>/dev/null || true
    echo
fi

echo "Done."
echo