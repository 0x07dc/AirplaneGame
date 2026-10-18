#!/bin/bash
# ==============================================================================
# AIRPLANE COMBAT SIMULATOR // VPS MASTER SERVER DEPLOYMENT SCRIPT
# Installs and runs master_server.py as a permanent systemd service (auto-restart on boot/crash).
# Domain target: jamilvoss.cyou
# ==============================================================================

set -euo pipefail

PORT="${1:-8080}"
INSTALL_DIR="/opt/airplane_master_server"
SERVICE_NAME="airplane-master-server"

echo "==> Deploying Airplane Game Master Server on port ${PORT}..."

# 1. Ensure Python 3 is installed
if ! command -v python3 >/dev/null 2>&1; then
    echo "==> Installing python3..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python
    fi
fi

# 2. Create destination directory and copy server script
mkdir -p "${INSTALL_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/master_server.py" "${INSTALL_DIR}/master_server.py"
chmod +x "${INSTALL_DIR}/master_server.py"

# 3. Create / update systemd service
cat << EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=Airplane Combat Simulator Master Server (jamilvoss.cyou)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/master_server.py --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 4. Enable and start service
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "==> Master Server successfully installed and started!"
echo "==> Service status:"
systemctl status "${SERVICE_NAME}" --no-pager -l

echo ""
echo "==> Test locally: curl http://127.0.0.1:${PORT}/health"
echo "==> Test domain:  curl http://jamilvoss.cyou:${PORT}/health"
