#!/bin/bash

# ============================================================
#                 ZiVPN MANAGER V2
# ============================================================

set -u
set -o pipefail

# ============================================================
# PATHS
# ============================================================

DB="/root/zivpn_users.db"
CONFIG="/etc/zivpn/config.json"

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo
    echo -e "${RED}ERROR: ZiVPN Manager must be run as root.${NC}"
    echo
    echo "Run:"
    echo "sudo zi"
    echo
    exit 1
fi

# ============================================================
# DEPENDENCY CHECK
# ============================================================

check_dependencies() {

    local missing=0

    for command in curl jq sqlite3 systemctl; do

        if ! command -v "$command" >/dev/null 2>&1; then

            echo -e "${RED}Missing required command: $command${NC}"

            missing=1

        fi

    done

    if [ "$missing" -eq 1 ]; then

        echo
        echo "Please run the installer again:"
        echo
        echo "sudo bash install.sh"
        echo

        exit 1

    fi
}

check_dependencies

# ============================================================
# DATABASE CHECK
# ============================================================

if [ ! -f "$DB" ]; then

    echo
    echo -e "${RED}Database not found.${NC}"
    echo
    echo "Run the installer first."
    echo

    exit 1
fi

# ============================================================
# CONFIG CHECK
# ============================================================

if [ ! -f "$CONFIG" ]; then

    echo
    echo -e "${RED}ZiVPN configuration not found:${NC}"
    echo "$CONFIG"
    echo

    exit 1
fi

# ============================================================
# PUBLIC IP
# ============================================================

get_public_ip() {

    local ip=""

    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)

    if [ -z "$ip" ]; then
        ip="Unavailable"
    fi

    echo "$ip"
}

# ============================================================
# HEADER
# ============================================================

header() {

    clear

    local public_ip

    public_ip=$(get_public_ip)

    echo -e "${CYAN}"
    echo "============================================================"
    echo "                    ZiVPN MANAGER V2"
    echo "============================================================"
    echo -e "${NC}"

    echo -e "${WHITE}Server IP : ${GREEN}${public_ip}${NC}"
    echo -e "${WHITE}Server    : ${GREEN}$(hostname)${NC}"
    echo -e "${WHITE}Date      : ${GREEN}$(date '+%Y-%m-%d')${NC}"
    echo -e "${WHITE}Time      : ${GREEN}$(date '+%H:%M:%S')${NC}"

    echo
    echo "------------------------------------------------------------"
    echo
}

# ============================================================
# PAUSE
# ============================================================

pause_screen() {

    echo
    read -r -p "Press ENTER to continue..."
}

# ============================================================
# SQL ESCAPE
# ============================================================

escape_sql() {

    printf "%s" "$1" | sed "s/'/''/g"
}

# ============================================================
# USER EXISTS
# ============================================================

user_exists() {

    local username="$1"
    local safe_username

    safe_username=$(escape_sql "$username")

    sqlite3 "$DB" \
        "SELECT COUNT(*) FROM users WHERE username='$safe_username';"
}

# ============================================================
# GET PASSWORD
# ============================================================

get_password() {

    local username="$1"
    local safe_username

    safe_username=$(escape_sql "$username")

    sqlite3 "$DB" \
        "SELECT password FROM users WHERE username='$safe_username';"
}

# ============================================================
# GET EXPIRY
# ============================================================

get_expiry() {

    local username="$1"
    local safe_username

    safe_username=$(escape_sql "$username")

    sqlite3 "$DB" \
        "SELECT expiry FROM users WHERE username='$safe_username';"
}

# ============================================================
# BACKUP CONFIG
# ============================================================

backup_config() {

    if [ -f "$CONFIG" ]; then

        cp "$CONFIG" "${CONFIG}.backup"

        chmod 600 "${CONFIG}.backup"

    fi
}

# ============================================================
# ADD PASSWORD TO ZIVPN
# ============================================================

add_password() {

    local password="$1"

    if [ ! -f "$CONFIG" ]; then

        echo -e "${RED}ZiVPN configuration not found.${NC}"

        return 1
    fi

    if ! jq empty "$CONFIG" >/dev/null 2>&1; then

        echo -e "${RED}ZiVPN configuration contains invalid JSON.${NC}"

        return 1
    fi

    backup_config

    local temp_config

    temp_config=$(mktemp)

    if ! jq --arg pass "$password" \
        '
        if .auth == null then
            .auth = {}
        else
            .
        end
        |
        if .auth.config == null then
            .auth.config = []
        else
            .
        end
        |
        .auth.config = ((.auth.config + [$pass]) | unique)
        ' \
        "$CONFIG" > "$temp_config"
    then

        rm -f "$temp_config"

        echo -e "${RED}Failed to modify ZiVPN configuration.${NC}"

        return 1
    fi

    if ! jq empty "$temp_config" >/dev/null 2>&1; then

        rm -f "$temp_config"

        echo -e "${RED}Generated configuration is invalid.${NC}"

        return 1
    fi

    mv "$temp_config" "$CONFIG"

    chmod 600 "$CONFIG"

    return 0
}

# ============================================================
# REMOVE PASSWORD FROM ZIVPN
# ============================================================

remove_password() {

    local password="$1"

    if [ ! -f "$CONFIG" ]; then
        return 1
    fi

    if ! jq empty "$CONFIG" >/dev/null 2>&1; then
        return 1
    fi

    backup_config

    local temp_config

    temp_config=$(mktemp)

    if ! jq --arg pass "$password" \
        '
        if .auth == null then
            .
        elif .auth.config == null then
            .
        else
            .auth.config = ((.auth.config // []) - [$pass])
        end
        ' \
        "$CONFIG" > "$temp_config"
    then

        rm -f "$temp_config"

        echo -e "${RED}Failed to modify ZiVPN configuration.${NC}"

        return 1
    fi

    mv "$temp_config" "$CONFIG"

    chmod 600 "$CONFIG"

    return 0
}

# ============================================================
# RESTART ZIVPN
# ============================================================

restart_zivpn() {

    echo

    if systemctl restart zivpn 2>/dev/null; then

        echo -e "${GREEN}ZiVPN restarted successfully.${NC}"

        return 0

    fi

    echo -e "${RED}Unable to restart ZiVPN.${NC}"
    echo
    echo "Check the service with:"
    echo
    echo "systemctl status zivpn"
    echo

    return 1
}

# ============================================================
# ADD USER
# ============================================================

add_user() {

    header

    echo -e "${GREEN}ADD ZIVPN USER${NC}"
    echo "------------------------------------------------------------"
    echo

    local public_ip
    local username
    local password
    local option
    local value
    local expiry
    local safe_username
    local safe_password

    public_ip=$(get_public_ip)

    read -r -p "Username: " username

    if [ -z "$username" ]; then

        echo -e "${RED}Username cannot be empty.${NC}"

        pause_screen
        return
    fi

    if [[ "$username" == *"|"* ]]; then

        echo -e "${RED}Username cannot contain |${NC}"

        pause_screen
        return
    fi

    if [ "$(user_exists "$username")" -gt 0 ]; then

        echo -e "${RED}Username already exists.${NC}"

        pause_screen
        return
    fi

    read -r -s -p "Password: " password

    echo

    if [ -z "$password" ]; then

        echo -e "${RED}Password cannot be empty.${NC}"

        pause_screen
        return
    fi

    echo
    echo "Duration"
    echo "------------------------------------------------------------"
    echo "1. Hours"
    echo "2. Days"
    echo "3. Months"
    echo

    read -r -p "Select [1-3]: " option

    case "$option" in

        1)

            read -r -p "Number of hours: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            expiry=$(( $(date +%s) + value * 3600 ))

            ;;

        2)

            read -r -p "Number of days: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            expiry=$(( $(date +%s) + value * 86400 ))

            ;;

        3)

            read -r -p "Number of months: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            expiry=$(( $(date +%s) + value * 2592000 ))

            ;;

        *)

            echo -e "${RED}Invalid selection.${NC}"

            pause_screen
            return
            ;;

    esac

    safe_username=$(escape_sql "$username")
    safe_password=$(escape_sql "$password")

    if ! sqlite3 "$DB" <<SQL
INSERT INTO users (username, password, expiry)
VALUES ('$safe_username', '$safe_password', '$expiry');
SQL
    then

        echo -e "${RED}Failed to create database user.${NC}"

        pause_screen
        return
    fi

    if ! add_password "$password"; then

        sqlite3 "$DB" \
            "DELETE FROM users WHERE username='$safe_username';"

        echo -e "${RED}Failed to add password to ZiVPN.${NC}"

        pause_screen
        return
    fi

    if ! restart_zivpn >/dev/null 2>&1; then

        echo
        echo -e "${YELLOW}Warning: user was created, but ZiVPN could not be restarted.${NC}"
        echo
    fi

    echo
    echo -e "${GREEN}"
    echo "============================================================"
    echo "                    USER CREATED"
    echo "============================================================"
    echo -e "${NC}"

    echo -e "IP Address : ${GREEN}${public_ip}${NC}"
    echo -e "Username   : ${GREEN}${username}${NC}"
    echo -e "Password   : ${GREEN}${password}${NC}"
    echo -e "Expires    : ${GREEN}$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')${NC}"

    echo
    echo "------------------------------------------------------------"
    echo
    echo -e "${GREEN}User successfully created.${NC}"
    echo

    pause_screen
}

# ============================================================
# DELETE USER
# ============================================================

delete_user() {

    header

    echo -e "${RED}DELETE USER${NC}"
    echo "------------------------------------------------------------"
    echo

    local username
    local password
    local safe_username

    read -r -p "Username: " username

    if [ -z "$username" ]; then

        echo -e "${RED}Username cannot be empty.${NC}"

        pause_screen
        return
    fi

    if [ "$(user_exists "$username")" -eq 0 ]; then

        echo -e "${RED}User not found.${NC}"

        pause_screen
        return
    fi

    password=$(get_password "$username")

    if ! remove_password "$password"; then

        echo -e "${RED}Failed to remove password from ZiVPN.${NC}"

        pause_screen
        return
    fi

    safe_username=$(escape_sql "$username")

    if ! sqlite3 "$DB" \
        "DELETE FROM users WHERE username='$safe_username';"
    then

        echo -e "${RED}Failed to delete database user.${NC}"

        pause_screen
        return
    fi

    restart_zivpn >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}User deleted successfully.${NC}"

    pause_screen
}

# ============================================================
# RENEW USER
# ============================================================

renew_user() {

    header

    echo -e "${YELLOW}RENEW USER${NC}"
    echo "------------------------------------------------------------"
    echo

    local username
    local old_expiry
    local now
    local base
    local option
    local value
    local new_expiry
    local safe_username

    read -r -p "Username: " username

    if [ -z "$username" ]; then

        echo -e "${RED}Username cannot be empty.${NC}"

        pause_screen
        return
    fi

    if [ "$(user_exists "$username")" -eq 0 ]; then

        echo -e "${RED}User not found.${NC}"

        pause_screen
        return
    fi

    old_expiry=$(get_expiry "$username")

    now=$(date +%s)

    if [ "$old_expiry" -gt "$now" ]; then
        base="$old_expiry"
    else
        base="$now"
    fi

    echo
    echo "Renew duration"
    echo "------------------------------------------------------------"
    echo "1. Hours"
    echo "2. Days"
    echo "3. Months"
    echo

    read -r -p "Select [1-3]: " option

    case "$option" in

        1)

            read -r -p "Hours: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            new_expiry=$((base + value * 3600))

            ;;

        2)

            read -r -p "Days: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            new_expiry=$((base + value * 86400))

            ;;

        3)

            read -r -p "Months: " value

            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then

                echo -e "${RED}Invalid duration.${NC}"

                pause_screen
                return
            fi

            new_expiry=$((base + value * 2592000))

            ;;

        *)

            echo -e "${RED}Invalid selection.${NC}"

            pause_screen
            return
            ;;

    esac

    safe_username=$(escape_sql "$username")

    if ! sqlite3 "$DB" \
        "UPDATE users SET expiry='$new_expiry' WHERE username='$safe_username';"
    then

        echo -e "${RED}Failed to renew user.${NC}"

        pause_screen
        return
    fi

    echo
    echo -e "${GREEN}User renewed successfully.${NC}"
    echo
    echo "Username  : $username"
    echo "New expiry: $(date -d "@$new_expiry" '+%Y-%m-%d %H:%M:%S')"

    pause_screen
}

# ============================================================
# LIST USERS
# ============================================================

list_users() {

    header

    echo -e "${GREEN}ACTIVE ZIVPN USERS${NC}"
    echo "------------------------------------------------------------"
    echo

    local public_ip
    local count

    public_ip=$(get_public_ip)

    count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users;")

    if [ "$count" -eq 0 ]; then

        echo -e "${YELLOW}No active users.${NC}"

        pause_screen
        return
    fi

    echo "Server IP: $public_ip"
    echo

    printf "%-16s %-16s %-20s %-22s\n" \
        "IP ADDRESS" "USERNAME" "PASSWORD" "EXPIRY"

    echo "--------------------------------------------------------------------------"

    sqlite3 "$DB" \
        "SELECT username,password,expiry
         FROM users
         ORDER BY expiry ASC;" |
    while IFS='|' read -r username password expiry
    do

        [ -z "$username" ] && continue

        expiry_date=$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')

        printf "%-16s %-16s %-20s %-22s\n" \
            "$public_ip" \
            "$username" \
            "$password" \
            "$expiry_date"

    done

    echo
    echo "Total users: $count"

    pause_screen
}

# ============================================================
# USER INFORMATION
# ============================================================

user_info() {

    header

    echo -e "${CYAN}USER INFORMATION${NC}"
    echo "------------------------------------------------------------"
    echo

    local public_ip
    local username
    local password
    local expiry

    public_ip=$(get_public_ip)

    read -r -p "Username: " username

    if [ -z "$username" ]; then

        echo -e "${RED}Username cannot be empty.${NC}"

        pause_screen
        return
    fi

    if [ "$(user_exists "$username")" -eq 0 ]; then

        echo -e "${RED}User not found.${NC}"

        pause_screen
        return
    fi

    password=$(get_password "$username")
    expiry=$(get_expiry "$username")

    echo
    echo "============================================================"
    echo "                     USER DETAILS"
    echo "============================================================"
    echo
    echo "IP Address : $public_ip"
    echo "Username   : $username"
    echo "Password   : $password"
    echo "Expires    : $(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "============================================================"

    pause_screen
}

# ============================================================
# SEARCH USERS
# ============================================================

search_user() {

    header

    echo -e "${CYAN}SEARCH USERS${NC}"
    echo "------------------------------------------------------------"
    echo

    local public_ip
    local search
    local safe_search

    public_ip=$(get_public_ip)

    read -r -p "Search username: " search

    if [ -z "$search" ]; then

        echo -e "${RED}Search cannot be empty.${NC}"

        pause_screen
        return
    fi

    safe_search=$(escape_sql "$search")

    echo

    printf "%-16s %-16s %-20s %-22s\n" \
        "IP ADDRESS" "USERNAME" "PASSWORD" "EXPIRY"

    echo "--------------------------------------------------------------------------"

    sqlite3 "$DB" \
        "SELECT username,password,expiry
         FROM users
         WHERE username LIKE '%$safe_search%'
         ORDER BY username;" |
    while IFS='|' read -r username password expiry
    do

        [ -z "$username" ] && continue

        expiry_date=$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')

        printf "%-16s %-16s %-20s %-22s\n" \
            "$public_ip" \
            "$username" \
            "$password" \
            "$expiry_date"

    done

    pause_screen
}

# ============================================================
# CHECK EXPIRY
# ============================================================

check_expiry() {

    local now
    local expired_count=0

    now=$(date +%s)

    while IFS='|' read -r username password expiry
    do

        [ -z "$username" ] && continue

        if [ "$now" -ge "$expiry" ]; then

            local safe_username

            safe_username=$(escape_sql "$username")

            remove_password "$password" >/dev/null 2>&1 || true

            sqlite3 "$DB" \
                "DELETE FROM users WHERE username='$safe_username';"

            expired_count=$((expired_count + 1))

  
