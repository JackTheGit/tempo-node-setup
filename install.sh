#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Tempo Node One-Click Installer
# Moderato Testnet
# ----------------------------

# Defaults (can be overridden by env vars)
CHAIN="${CHAIN:-testnet}"
DATADIR="${DATADIR:-/root/tempo/data}"
KEYDIR="${KEYDIR:-/root/tempo/keys}"
FEE_RECIPIENT="${FEE_RECIPIENT:-}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8545}"
P2P_PORT="${P2P_PORT:-30303}"
DISCOVERY_ADDR="${DISCOVERY_ADDR:-0.0.0.0}"
DISCOVERY_PORT="${DISCOVERY_PORT:-30303}"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-true}"   # true/false

TEMPO_BIN="/usr/local/bin/tempo"
SERVICE_FILE="/etc/systemd/system/tempo.service"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "==> Tempo one-click installer (CHAIN=${CHAIN})"

if [[ -z "$FEE_RECIPIENT" ]]; then
  echo "ERROR: Missing FEE_RECIPIENT."
  echo "Example:"
  echo "  FEE_RECIPIENT=0xYourWalletHere bash install.sh"
  exit 1
fi

echo "==> Updating packages + installing dependencies..."
sudo apt update && sudo apt -y upgrade
sudo apt install -y curl screen iptables build-essential git wget lz4 jq make gcc nano openssl \
  automake autoconf htop nvme-cli pkg-config libssl-dev libleveldb-dev \
  tar clang bsdmainutils ncdu unzip ca-certificates net-tools iputils-ping

if ! need_cmd cargo; then
  echo "==> Installing Rust (cargo)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
else
  echo "==> Rust already installed."
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env" || true
fi

echo "==> Installing Tempo from source..."
sudo cargo install --git https://github.com/tempoxyz/tempo.git tempo --root /usr/local --force

if [[ ! -x "$TEMPO_BIN" ]]; then
  echo "ERROR: tempo binary not found at $TEMPO_BIN"
  exit 1
fi

echo "==> Tempo installed: $($TEMPO_BIN --version || true)"

echo "==> Creating key directory: $KEYDIR"
sudo mkdir -p "$KEYDIR"

if [[ ! -f "$KEYDIR/signing.key" ]]; then
  echo "==> Generating consensus signing key..."
  "$TEMPO_BIN" consensus generate-private-key --output "$KEYDIR/signing.key"
else
  echo "==> signing.key already exists, skipping key generation."
fi

echo "==> Creating data directory: $DATADIR"
sudo mkdir -p "$DATADIR"

# Snapshot download
echo "==> Downloading chain snapshot (this can take a while)..."
"$TEMPO_BIN" download --datadir "$DATADIR"

# Optional systemd service
if [[ "$INSTALL_SYSTEMD" == "true" ]]; then
  echo "==> Installing systemd service: $SERVICE_FILE"

  sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Tempo Node (Moderato Testnet)
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root

ExecStart=$TEMPO_BIN node --datadir $DATADIR \\
  --chain $CHAIN \\
  --follow \\
  --http --http.addr $HTTP_ADDR --http.port $HTTP_PORT --http.api eth,net,web3,txpool,trace \\
  --port $P2P_PORT --discovery.addr $DISCOVERY_ADDR --discovery.port $DISCOVERY_PORT \\
  --consensus.signing-key $KEYDIR/signing.key \\
  --consensus.fee-recipient $FEE_RECIPIENT

Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable tempo
  sudo systemctl restart tempo

  echo "==> systemd service installed and started."
  echo "==> Check logs: sudo journalctl -u tempo -f"
else
  echo "==> INSTALL_SYSTEMD=false, skipping systemd service."
  echo "==> You can run Tempo manually (screen):"
  echo "  screen -S tempo"
  echo "  $TEMPO_BIN node --datadir $DATADIR --chain $CHAIN --port $P2P_PORT --discovery.addr $DISCOVERY_ADDR --discovery.port $DISCOVERY_PORT \\"
  echo "    --consensus.signing-key $KEYDIR/signing.key --consensus.fee-recipient $FEE_RECIPIENT"
fi

echo ""
echo "✅ Done."
echo "RPC: http://$HTTP_ADDR:$HTTP_PORT (local by default)"
echo "P2P: tcp/udp $P2P_PORT"
