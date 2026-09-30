#!/bin/bash

# ==========================================
# ZiVPN Manager Auto Installer
# ==========================================


DB="/root/zivpn_users.db"
CONFIG="/etc/zivpn/config.json"
ZI="/usr/local/bin/zi"


# ---------- ROOT CHECK ----------

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi



# ---------- REQUIREMENTS ----------

install_packages(){

echo "[+] Installing packages..."

apt update -y

apt install -y \
wget \
curl \
jq \
sqlite3


}



# ---------- INSTALL ZIVPN ----------

install_zivpn(){

if [ ! -f "$CONFIG" ]; then

echo "[+] Installing ZiVPN..."

cd /root


wget -O zi.sh \
https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/zi.sh


chmod +x zi.sh


bash zi.sh


else

echo "[+] ZiVPN already installed"

fi

}



# ---------- DATABASE ----------

create_db(){

sqlite3 "$DB" <<EOF

CREATE TABLE IF NOT EXISTS users(

id INTEGER PRIMARY KEY AUTOINCREMENT,

username TEXT UNIQUE,

password TEXT,

expiry INTEGER

);

EOF

}



# ---------- RESTART ----------

restart_zivpn(){

systemctl restart zivpn 2>/dev/null

}



# ---------- ADD PASSWORD ----------

add_password(){

PASS="$1"


cp "$CONFIG" "$CONFIG.backup"


jq \
".auth.config += [\"$PASS\"]" \
"$CONFIG" > /tmp/config.json


mv /tmp/config.json "$CONFIG"


restart_zivpn

}



# ---------- REMOVE PASSWORD ----------

remove_password(){

PASS="$1"


cp "$CONFIG" "$CONFIG.backup"


jq \
".auth.config -= [\"$PASS\"]" \
"$CONFIG" > /tmp/config.json


mv /tmp/config.json "$CONFIG"


restart_zivpn

}




# ---------- ADD USER ----------

add_user(){


echo "
=====================
 ADD ZIVPN USER
=====================
"


read -p "Username: " username

read -p "Password: " password



echo "

Duration

1) Hours
2) Days
3) Months

"


read -p "Select: " option



case $option in

1)

read -p "Hours: " value

expiry=$(( $(date +%s)+value*3600 ))

;;

2)

read -p "Days: " value

expiry=$(( $(date +%s)+value*86400 ))

;;

3)

read -p "Months: " value

expiry=$(( $(date +%s)+value*2592000 ))

;;

*)

echo "Invalid"

return

;;

esac



sqlite3 "$DB" <<EOF

INSERT INTO users

(username,password,expiry)

VALUES

('$username','$password','$expiry');

EOF



add_password "$password"



echo "

=====================
 USER CREATED
=====================

Username: $username

Password: $password

Expiry:
$(date -d @$expiry)

=====================

"



}



# ---------- DELETE USER ----------


delete_user(){

read -p "Username: " username



password=$(sqlite3 "$DB" \
"SELECT password FROM users WHERE username='$username';")



if [ -z "$password" ]; then

echo "User not found"

return

fi



remove_password "$password"



sqlite3 "$DB" \
"DELETE FROM users WHERE username='$username';"



echo "Deleted successfully"


}




# ---------- EXPIRY CHECK ----------


expiry_check(){


NOW=$(date +%s)



sqlite3 "$DB" \
"SELECT username,password,expiry FROM users;" |

while IFS="|" read username password expiry

do


if [ "$NOW" -ge "$expiry" ]; then


echo "Expired: $username"


remove_password "$password"


sqlite3 "$DB" \
"DELETE FROM users WHERE username='$username';"


fi


done


}




# ---------- LIST ----------


list_users(){

echo "

================
 USERS
================
"


sqlite3 -column -header "$DB" "

SELECT

username,

datetime(expiry,'unixepoch') expiry

FROM users;

"


}




# ---------- INSTALL ZI COMMAND ----------


install_command(){


cp "$0" "$ZI"


chmod +x "$ZI"



echo "

=================================

Installation Complete

Type:

zi

to access ZiVPN Manager

=================================

"

}




# ---------- MENU ----------


menu(){

while true

do


expiry_check


clear


echo "

================================
          ZiVPN MANAGER
================================

1. Add User

2. Delete User

3. List Users

4. Restart ZiVPN

5. Exit

"



read -p "Select: " choice



case $choice in


1)
add_user
;;


2)
delete_user
;;


3)
list_users
;;


4)
restart_zivpn
;;


5)
exit
;;


*)

echo "Invalid option"

;;

esac



read -p "Press ENTER..."



done


}




# ---------- START ----------


install_packages

install_zivpn

create_db

install_command

menu
