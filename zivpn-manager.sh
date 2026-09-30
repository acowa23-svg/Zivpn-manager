#!/bin/bash

set -u
set -o pipefail

DB="/root/zivpn_users.db"
CONFIG="/etc/zivpn/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

die() {
    echo -e "${RED}$1${NC}"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    die "ERROR: Run this manager as root."
fi

for cmd in curl jq sqlite3 systemctl sed date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Missing required command: $cmd"
    fi
done

if [ ! -f "$DB" ]; then
    die "Database not found: $DB"
fi

if [ ! -f "$CONFIG" ]; then
    die "ZiVPN configuration not found: $CONFIG"
fi

get_public_ip() {
    local ip

    ip=$(curl -4 -fsS --max-time 5 \
        https://api.ipify.org 2>/dev/null || true)

    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
    else
        printf '%s\n' "Unavailable"
    fi
}

header() {
    clear 2>/dev/null || true

    local ip
    ip=$(get_public_ip)

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}                    ZiVPN MANAGER V2${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${WHITE}Server IP : ${GREEN}$ip${NC}"
    echo -e "${WHITE}Server    : ${GREEN}$(hostname)${NC}"
    echo -e "${WHITE}Date      : ${GREEN}$(date '+%Y-%m-%d')${NC}"
    echo -e "${WHITE}Time      : ${GREEN}$(date '+%H:%M:%S')${NC}"
    echo "------------------------------------------------------------"
    echo
}

pause_screen() {
    echo
    read -r -p "Press ENTER to continue..."
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

user_exists() {
    local username
    username=$(sql_escape "$1")

    sqlite3 "$DB" \
        "SELECT COUNT(*) FROM users WHERE username='$username';"
}

get_password() {
    local username
    username=$(sql_escape "$1")

    sqlite3 "$DB" \
        "SELECT password FROM users WHERE username='$username';"
}

get_expiry() {
    local username
    username=$(sql_escape "$1")

    sqlite3 "$DB" \
        "SELECT expiry FROM users WHERE username='$username';"
}

restart_zivpn() {

    if systemctl restart zivpn 2>/dev/null; then
        echo -e "${GREEN}ZiVPN restarted successfully.${NC}"
        return 0
    fi

    echo -e "${RED}Unable to restart ZiVPN.${NC}"
    echo
    echo "Run:"
    echo "systemctl status zivpn"

    return 1
}

add_password() {

    local password="$1"
    local temp_config

    if ! jq empty "$CONFIG" >/dev/null 2>&1; then
        return 1
    fi

    cp -f "$CONFIG" "${CONFIG}.backup" || return 1

    temp_config=$(mktemp) || return 1

    if ! jq --arg pass "$password" '
        .auth = (.auth // {}) |
        .auth.config = (.auth.config // []) |
        .auth.config = ((.auth.config + [$pass]) | unique)
    ' "$CONFIG" > "$temp_config"; then

        rm -f "$temp_config"
        return 1
    fi

    if ! jq empty "$temp_config" >/dev/null 2>&1; then
        rm -f "$temp_config"
        return 1
    fi

    mv "$temp_config" "$CONFIG"
    chmod 600 "$CONFIG"

    return 0
}

remove_password() {

    local password="$1"
    local temp_config

    if ! jq empty "$CONFIG" >/dev/null 2>&1; then
        return 1
    fi

    cp -f "$CONFIG" "${CONFIG}.backup" || return 1

    temp_config=$(mktemp) || return 1

    if ! jq --arg pass "$password" '
        if .auth == null then
            .
        elif .auth.config == null then
            .
        else
            .auth.config = ((.auth.config // []) - [$pass])
        end
    ' "$CONFIG" > "$temp_config"; then

        rm -f "$temp_config"
        return 1
    fi

    mv "$temp_config" "$CONFIG"
    chmod 600 "$CONFIG"

    return 0
}

add_user() {

    header

    echo -e "${GREEN}ADD ZIVPN USER${NC}"
    echo "------------------------------------------------------------"

    local ip
    local username
    local password
    local option
    local value
    local multiplier
    local expiry
    local safe_username
    local safe_password

    ip=$(get_public_ip)

    echo
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
            multiplier=3600
            ;;

        2)
            read -r -p "Number of days: " value
            multiplier=86400
            ;;

        3)
            read -r -p "Number of months: " value
            multiplier=2592000
            ;;

        *)
            echo -e "${RED}Invalid selection.${NC}"
            pause_screen
            return
            ;;

    esac

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        echo -e "${RED}Invalid duration.${NC}"
        pause_screen
        return
    fi

    expiry=$(( $(date +%s) + value * multiplier ))

    safe_username=$(sql_escape "$username")
    safe_password=$(sql_escape "$password")

    if ! sqlite3 "$DB" \
        "INSERT INTO users(username,password,expiry)
         VALUES('$safe_username','$safe_password','$expiry');"
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

    restart_zivpn >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}                    USER CREATED${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo
    echo "IP Address : $ip"
    echo "Username   : $username"
    echo "Password   : $password"
    echo "Expires    : $(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "------------------------------------------------------------"
    echo
    echo -e "${GREEN}User successfully created.${NC}"

    pause_screen
}

delete_user() {

    header

    echo -e "${RED}DELETE USER${NC}"
    echo "------------------------------------------------------------"

    local username
    local password
    local safe_username

    echo
    read -r -p "Username: " username

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

    safe_username=$(sql_escape "$username")

    sqlite3 "$DB" \
        "DELETE FROM users WHERE username='$safe_username';"

    restart_zivpn >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}User deleted successfully.${NC}"

    pause_screen
}

renew_user() {

    header

    echo -e "${YELLOW}RENEW USER${NC}"
    echo "------------------------------------------------------------"

    local username
    local old_expiry
    local now
    local base
    local option
    local value
    local multiplier
    local new_expiry
    local safe_username

    echo
    read -r -p "Username: " username

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
            multiplier=3600
            ;;

        2)
            read -r -p "Days: " value
            multiplier=86400
            ;;

        3)
            read -r -p "Months: " value
            multiplier=2592000
            ;;

        *)
            echo -e "${RED}Invalid selection.${NC}"
            pause_screen
            return
            ;;

    esac

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        echo -e "${RED}Invalid duration.${NC}"
        pause_screen
        return
    fi

    new_expiry=$((base + value * multiplier))

    safe_username=$(sql_escape "$username")

    sqlite3 "$DB" \
        "UPDATE users SET expiry='$new_expiry'
         WHERE username='$safe_username';"

    echo
    echo -e "${GREEN}User renewed successfully.${NC}"
    echo
    echo "Username  : $username"
    echo "New expiry: $(date -d "@$new_expiry" '+%Y-%m-%d %H:%M:%S')"

    pause_screen
}

list_users() {

    header

    echo -e "${GREEN}ACTIVE ZIVPN USERS${NC}"
    echo "------------------------------------------------------------"

    local ip
    local count
    local username
    local password
    local expiry

    ip=$(get_public_ip)

    count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users;")

    if [ "$count" -eq 0 ]; then
        echo
        echo -e "${YELLOW}No active users.${NC}"
        pause_screen
        return
    fi

    echo
    printf "%-16s %-16s %-20s %-22s\n" \
        "IP ADDRESS" "USERNAME" "PASSWORD" "EXPIRY"

    echo "--------------------------------------------------------------------------"

    while IFS='|' read -r username password expiry
    do

        [ -n "$username" ] || continue

        printf "%-16s %-16s %-20s %-22s\n" \
            "$ip" \
            "$username" \
            "$password" \
            "$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"

    done < <(
        sqlite3 "$DB" \
            "SELECT username,password,expiry
             FROM users
             ORDER BY expiry ASC;"
    )

    echo
    echo "Total users: $count"

    pause_screen
}

user_info() {

    header

    echo -e "${CYAN}USER INFORMATION${NC}"
    echo "------------------------------------------------------------"

    local ip
    local username
    local password
    local expiry

    ip=$(get_public_ip)

    echo
    read -r -p "Username: " username

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
    echo "IP Address : $ip"
    echo "Username   : $username"
    echo "Password   : $password"
    echo "Expires    : $(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "============================================================"

    pause_screen
}

search_user() {

    header

    echo -e "${CYAN}SEARCH USERS${NC}"
    echo "------------------------------------------------------------"

    local ip
    local search
    local safe_search
    local username
    local password
    local expiry

    ip=$(get_public_ip)

    echo
    read -r -p "Search username: " search

    if [ -z "$search" ]; then
        echo -e "${RED}Search cannot be empty.${NC}"
        pause_screen
        return
    fi

    safe_search=$(sql_escape "$search")

    echo

    printf "%-16s %-16s %-20s %-22s\n" \
        "IP ADDRESS" "USERNAME" "PASSWORD" "EXPIRY"

    echo "--------------------------------------------------------------------------"

    while IFS='|' read -r username password expiry
    do

        [ -n "$username" ] || continue

        printf "%-16s %-16s %-20s %-22s\n" \
            "$ip" \
            "$username" \
            "$password" \
            "$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')"

    done < <(
        sqlite3 "$DB" \
            "SELECT username,password,expiry
             FROM users
             WHERE username LIKE '%$safe_search%'
             ORDER BY username;"
    )

    pause_screen
}

check_expiry() {

    local now
    local username
    local password
    local expiry
    local safe_username
    local expired=0

    now=$(date +%s)

    while IFS='|' read -r username password expiry
    do

        [ -n "$username" ] || continue

        if [ "$now" -ge "$expiry" ]; then

            safe_username=$(sql_escape "$username")

            remove_password "$password" >/dev/null 2>&1 || true

            sqlite3 "$DB" \
                "DELETE FROM users
                 WHERE username='$safe_username';"

            expired=$((expired + 1))

        fi

    done < <(
        sqlite3 "$DB" \
            "SELECT username,password,expiry FROM users;"
    )

    if [ "$expired" -gt 0 ]; then
        systemctl restart zivpn >/dev/null 2>&1 || true
    fi
}

backup_database() {

    local directory
    local file

    directory="/root/zivpn-backups"

    mkdir -p "$directory"

    file="$directory/zivpn_users_$(date '+%Y%m%d_%H%M%S').db"

    if cp "$DB" "$file"; then

        chmod 600 "$file"

        echo
        echo -e "${GREEN}Database backup created:${NC}"
        echo
        echo "$file"

    else

        echo -e "${RED}Failed to create backup.${NC}"

    fi

    pause_screen
}

menu() {

    while true
    do

        check_expiry

        header

        echo -e "${GREEN}1.${NC} Add User"
        echo -e "${GREEN}2.${NC} Delete User"
        echo -e "${GREEN}3.${NC} Renew User"
        echo -e "${GREEN}4.${NC} List Users"
        echo -e "${GREEN}5.${NC} Search User"
        echo -e "${GREEN}6.${NC} User Information"
        echo -e "${GREEN}7.${NC} Restart ZiVPN"
        echo -e "${GREEN}8.${NC} Backup Database"
        echo -e "${GREEN}9.${NC} Exit"

        echo
        echo "------------------------------------------------------------"
        echo

        read -r -p "Select option [1-9]: " choice

        case "$choice" in

            1)
                add_user
                ;;

            2)
                delete_user
                ;;

            3)
                renew_user
                ;;

            4)
                list_users
                ;;

            5)
                search_user
                ;;

            6)
                user_info
                ;;

            7)
                header
                restart_zivpn
                pause_screen
                ;;

            8)
                backup_database
                ;;

            9)
                clear 2>/dev/null || true
                echo
                echo -e "${GREEN}ZiVPN Manager closed.${NC}"
                echo
                exit 0
                ;;

            "")
                ;;

            *)
                echo
                echo -e "${RED}Invalid option. Choose 1-9.${NC}"
                sleep 1
                ;;

        esac

    done
}

menu
