#!/bin/bash

# ============================================================
#                 ZiVPN MANAGER V2
#                    INSTALLER
# ============================================================

set -e

# ============================================================
# GITHUB SETTINGS
# ============================================================

GITHUB_USER="acowa23-svg"
REPO="zivpn-manager"
BRANCH="main"

MANAGER_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO}/${BRANCH}/zivpn-manager.sh"

# ============================================================
# PATHS
# ============================================================

MANAGER="/usr/local/lib/zivpn-manager.sh"
COMMAND="/usr/local/bin/zi"

DB="/root/zivpn_users.db"
CONFIG="/etc/zivpn/config.json"

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo
    echo "ERROR: This installer must be run as root."
    echo
    echo "Run:"
    echo "sudo bash install.sh"
    echo
    exit 1
fi

# ============================================================
# HEADER
# ============================================================

echo
echo "============================================================"
echo "                 ZiVPN MANAGER V2"
echo "                    INSTALLER"
echo "============================================================"
echo

# ============================================================
# PACKAGE INSTALLATION
# ============================================================

echo "[1/5] Updating package lists..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

echo
echo "[2/5] Installing required packages..."

apt-get install -y \
    curl \
    wget \
    jq \
    sqlite3

# ============================================================
# INSTALL / CHECK ZIVPN
# ============================================================

echo
echo "[3/5] Checking ZiVPN..."
echo

if [ -f "$CONFIG" ]; then

    echo "ZiVPN configuration found:"
    echo "$CONFIG"
    echo
    echo "Skipping ZiVPN installation."

else

    echo "ZiVPN configuration was not found."
    echo "Downloading ZiVPN installer..."
    echo

    cd /root

    if ! wget -q --show-progress \
        -O /root/zi.sh \
        https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/zi.sh
    then

        echo
        echo "ERROR: Could not download the ZiVPN installer."
        echo
        exit 1

    fi

    chmod +x /root/zi.sh

    echo
    echo "Starting ZiVPN installer..."
    echo
    echo "IMPORTANT: If the ZiVPN installer asks questions,"
    echo "complete those questions before continuing."
    echo

    bash /root/zi.sh
fi

# ============================================================
# VERIFY ZIVPN CONFIG
# ============================================================

if [ ! -f "$CONFIG" ]; then

    echo
    echo "============================================================"
    echo "ERROR: ZiVPN configuration was not found."
    echo "============================================================"
    echo
    echo "Expected:"
    echo "$CONFIG"
    echo
    echo "The ZiVPN installation may not have completed correctly."
    echo

    exit 1
fi

echo
echo "ZiVPN configuration verified."

# ============================================================
# VERIFY JSON
# ============================================================

if ! jq empty "$CONFIG" >/dev/null 2>&1; then

    echo
    echo "ERROR: $CONFIG is not valid JSON."
    echo

    exit 1
fi

echo "ZiVPN JSON configuration verified."

# ============================================================
# DATABASE
# ============================================================

echo
echo "[4/5] Creating database..."

if [ ! -f "$DB" ]; then

    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    expiry INTEGER NOT NULL
);
SQL

else

    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    expiry INTEGER NOT NULL
);
SQL

fi

chmod 600 "$DB"

echo "Database ready:"
echo "$DB"

# ============================================================
# DOWNLOAD MANAGER
# ============================================================

echo
echo "[5/5] Downloading ZiVPN Manager..."

mkdir -p /usr/local/lib

TEMP_MANAGER="/tmp/zivpn-manager.sh"

if ! wget -q \
    -O "$TEMP_MANAGER" \
    "$MANAGER_URL"
then

    echo
    echo "============================================================"
    echo "ERROR: Could not download the manager."
    echo "============================================================"
    echo
    echo "URL:"
    echo "$MANAGER_URL"
    echo
    echo "Check that:"
    echo "1. The GitHub repository exists."
    echo "2. The repository is public."
    echo "3. zivpn-manager.sh is in the main branch."
    echo

    rm -f "$TEMP_MANAGER"

    exit 1
fi

# Check that downloaded file is not empty

if [ ! -s "$TEMP_MANAGER" ]; then

    echo
    echo "ERROR: Downloaded manager file is empty."
    echo

    rm -f "$TEMP_MANAGER"

    exit 1
fi

# Install manager

mv "$TEMP_MANAGER" "$MANAGER"

chmod 700 "$MANAGER"

# ============================================================
# CREATE ZI COMMAND
# ============================================================

cat > "$COMMAND" <<'EOF'
#!/bin/bash

exec /usr/local/lib/zivpn-manager.sh "$@"
EOF

chmod 755 "$COMMAND"

# ============================================================
# FINAL CHECK
# ============================================================

if [ ! -x "$MANAGER" ]; then

    echo
    echo "ERROR: Manager installation failed."
    echo

    exit 1
fi

if [ ! -x "$COMMAND" ]; then

    echo
    echo "ERROR: zi command installation failed."
    echo

    exit 1
fi

# ============================================================
# FINISHED
# ============================================================

echo
echo "============================================================"
echo "             INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "ZiVPN Manager V2 has been installed successfully."
echo
echo "Open the manager with:"
echo
echo "    zi"
echo
echo "Manager:"
echo "    $MANAGER"
echo
echo "Database:"
echo "    $DB"
echo
echo "Configuration:"
echo "    $CONFIG"
echo
echo "============================================================"
echo
