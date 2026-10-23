#!/bin/bash
# cekmac.sh - cek perangkat via MAC (+IP bila ada) - baca daftar dari devices.conf
# Nambah device = tambah 1 baris di devices.conf, tanpa edit script.
# Urutan cek per device: scan broadcast -> unicast ke IP (bangunkan HP sleep)
#                        -> cek TCP PORT bila diisi -> MAC cocok = ONLINE

export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin"

BOT_TOKEN="01010101:ABCDEF-abcdef010101"
CHAT_ID="01010101"
INTERFACE="${INTERFACE:-}"
SCAN_PASS=3
SCAN_DELAY=5
ARP_SCAN_ARGS="--retry 4 --timeout 1500"
DEFAULT_MAX_MISS=1
AUTO_UPDATE_CONF="${AUTO_UPDATE_CONF:-1}"
NOTIFY_IP_CHANGE="${NOTIFY_IP_CHANGE:-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/devices.conf"
LOG_FILE="$SCRIPT_DIR/cekmac.log"
STATE_DIR="$SCRIPT_DIR/.state_cekmac"
mkdir -p "$STATE_DIR"

# Fallback bila devices.conf belum ada (daftar inline lama)
FALLBACK_LIST=(
"aa:bb:cc:dd:ee:ff|PC01"
"aa:bb:cc:dd:ee:ff|HP01"
)

detect_iface() {
    if [ -n "$INTERFACE" ]; then echo "$INTERFACE"; return; fi
    local IF
    IF="$(ip route get 192.168.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"
    [ -z "$IF" ] && IF="$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)"
    [ -z "$IF" ] && IF="eth0"
    echo "$IF"
}

IFACE="$(detect_iface)"
echo "Interface: $IFACE"

if ! command -v arp-scan >/dev/null 2>&1; then
    echo "WARN: arp-scan tidak ditemukan; fallback ke ip neigh (kurang akurat). Install: apt install arp-scan"
fi

# Bangunkan device yang IP-nya diketahui SEBELUM scan broadcast.
# Ini langkah paling ampuh lawan HP sleep: unicast dulu, baru sapu broadcast.
wake_known_ips() {
    while IFS= read -r LINE; do
        case "$LINE" in ''|\#*) continue;; esac
        local IP
        IP="$(echo "$LINE" | cut -d'|' -f3)"
        [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        if command -v arping >/dev/null 2>&1; then
            arping -c 1 -w 2 -I "$IFACE" "$IP" >/dev/null 2>&1 &
        else
            ping -c 1 -W 1 "$IP" >/dev/null 2>&1 &
        fi
    done < <(device_lines)
    wait || true
    # broadcast ping untuk sisanya yang tanpa IP tetap
    local BCAST
    BCAST="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/brd/ {print $6}' | head -n1)"
    [ -n "$BCAST" ] && ping -c 1 -W 1 -b "$BCAST" >/dev/null 2>&1 || true
}

device_lines() {
    if [ -f "$CONF" ]; then
        grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$'
    else
        printf '%s\n' "${FALLBACK_LIST[@]}"
    fi
}

scan_once() {
    if command -v arp-scan >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            # shellcheck disable=SC2086
            arp-scan --interface="$IFACE" $ARP_SCAN_ARGS --localnet 2>/dev/null || true
        else
            # shellcheck disable=SC2086
            sudo -n /usr/sbin/arp-scan --interface="$IFACE" $ARP_SCAN_ARGS --localnet 2>/dev/null \
            || sudo -n arp-scan --interface="$IFACE" $ARP_SCAN_ARGS --localnet 2>/dev/null || true
        fi
    fi
    ip neigh show dev "$IFACE" 2>/dev/null || ip neigh show 2>/dev/null || true
}

# Cek unicast ke IP yang diketahui + verifikasi MAC (untuk HP sleep)
check_unicast() {
    local MAC="$1" KNOWNIP="$2" PORT="$3"
    [ -z "$KNOWNIP" ] && return 1
    [[ "$KNOWNIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    if command -v arping >/dev/null 2>&1; then
        if arping -c 3 -w 5 -I "$IFACE" "$KNOWNIP" 2>/dev/null | grep -qi "$MAC"; then
            echo "$KNOWNIP"
            return 0
        fi
    fi
    if ping -c 3 -W 2 "$KNOWNIP" >/dev/null 2>&1; then
        local FOUND
        FOUND="$(ip neigh show "$KNOWNIP" 2>/dev/null | grep -i "$MAC" | grep -vi FAILED | awk '{print $1}' | head -n1)"
        [ -n "$FOUND" ] && { echo "$FOUND"; return 0; }
    fi
    # terakhir: port TCP terbuka = device hidup (walau MAC tak terlihat di ARP)
    if [ -n "$PORT" ]; then
        if timeout 3 bash -c "echo > /dev/tcp/$KNOWNIP/$PORT" >/dev/null 2>&1; then
            echo "$KNOWNIP:$PORT"
            return 0
        fi
    fi
    return 1
}

# Update kolom IP (field 3) di devices.conf secara atomik, preserve komen + field lain.
# Dipanggil hanya dengan IPv4 valid yang sudah terbukti ONLINE.
update_conf_ip() {
    local MAC_LC="$1" NEWIP="$2"
    [[ "$NEWIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [ -f "$CONF" ] || return 1
    [ -w "$CONF" ] || { echo "WARN: $CONF tidak writable, skip auto-update $MAC_LC -> $NEWIP"; return 1; }
    # Simpan owner awal agar file tetap milik user walau diupdate oleh cron root.
    local CONF_OWNER=""
    CONF_OWNER="$(stat -c '%u:%g' "$CONF" 2>/dev/null || true)"
    local TMP
    TMP="$(mktemp "$CONF.tmp.XXXXXX")" || return 1
    if ! awk -F'|' -v mac="$MAC_LC" -v newip="$NEWIP" '
        BEGIN { OFS="|"; }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next; }
        { if (tolower($1) == tolower(mac)) $3 = newip; print; }
    ' "$CONF" > "$TMP"; then
        rm -f "$TMP"
        return 1
    fi
    # mv atomik di filesystem yang sama, dengan lock agar aman dari cron overlap.
    # Lock di SCRIPT_DIR (bukan STATE_DIR) karena STATE_DIR milik root saat jalan via cron.
    # chmod + chown balik agar tetap editable user setelah mv oleh root (mktemp default 600/root).
    if command -v flock >/dev/null 2>&1; then
        if ( flock -n 200 || { echo "WARN: conf locked, skip auto-update $MAC_LC"; rm -f "$TMP"; exit 1; }
            mv "$TMP" "$CONF"
            chmod 644 "$CONF" 2>/dev/null || true
            [ -n "$CONF_OWNER" ] && chown "$CONF_OWNER" "$CONF" 2>/dev/null || true
            chmod 666 "$SCRIPT_DIR/.devices.lock" 2>/dev/null || true
        ) 200>"$SCRIPT_DIR/.devices.lock"; then
            return 0
        else
            rm -f "$TMP"
            return 1
        fi
    else
        mv "$TMP" "$CONF"
        chmod 644 "$CONF" 2>/dev/null || true
        [ -n "$CONF_OWNER" ] && chown "$CONF_OWNER" "$CONF" 2>/dev/null || true
    fi
}

OFFLINE_LIST=""
RECOVERED_LIST=""
IP_CHANGED_LIST=""
TOTAL=0

COMBINED=""
wake_known_ips
for ((i=1; i<=SCAN_PASS; i++)); do
    echo "--- scan pass $i/$SCAN_PASS ---"
    COMBINED+="$(scan_once)"$'\n'
    [ "$i" -lt "$SCAN_PASS" ] && sleep "$SCAN_DELAY"
done

while IFS= read -r LINE; do
    case "$LINE" in ''|\#*) continue;; esac
    MAC=$(echo "$LINE" | cut -d'|' -f1 | tr '[:upper:]' '[:lower:]')
    ALIAS=$(echo "$LINE" | cut -d'|' -f2)
    KNOWNIP=$(echo "$LINE" | cut -d'|' -f3)
    PORT=$(echo "$LINE" | cut -d'|' -f4)
    MAX_MISS=$(echo "$LINE" | cut -d'|' -f5)
    [ -z "$MAX_MISS" ] && MAX_MISS=$DEFAULT_MAX_MISS
    [ -z "$MAC" ] || [ -z "$ALIAS" ] && continue
    TOTAL=$((TOTAL + 1))

    SAFE="$(echo "$ALIAS" | tr -c 'A-Za-z0-9' '_')"
    STATE_FILE="$STATE_DIR/${SAFE}.count"
    LASTIP_FILE="$STATE_DIR/${SAFE}.lastip"
    [ -f "$STATE_FILE" ] || echo 0 > "$STATE_FILE"
    FAIL_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

    # Hanya IPv4 fresh yang dihitung ONLINE via broadcast.
    # STALE/FAILED/INCOMPLETE dari ip neigh diabaikan karena awet dan bikin
    # false ONLINE (kasus HP010: arp-scan sudah hilang tapi STALE .19 masih ada).
    # Device idle yang hanya STALE tetap ketemu via unicast arping di bawah.
    IP=$(echo "$COMBINED" | grep -i "$MAC" | grep -viE "FAILED|INCOMPLETE|STALE" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]' | awk '{print $1}' | head -n1)

    # Broadcast miss -> unicast ke IP conf, lalu IP terakhir terlihat
    if [ -z "$IP" ]; then
        IP="$(check_unicast "$MAC" "$KNOWNIP" "$PORT")" || true
        [ -n "$IP" ] && echo "UNICAST-HIT: $ALIAS ($MAC) -> $IP"
    fi
    if [ -z "$IP" ] && [ -f "$LASTIP_FILE" ]; then
        IP="$(check_unicast "$MAC" "$(cat "$LASTIP_FILE" 2>/dev/null)" "$PORT")" || true
        [ -n "$IP" ] && echo "LASTIP-HIT: $ALIAS ($MAC) -> $IP"
    fi

    if [ -z "$IP" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$STATE_FILE"
        echo "MISS $FAIL_COUNT/$MAX_MISS: $ALIAS ($MAC)"
        if [ "$FAIL_COUNT" -ge "$MAX_MISS" ]; then
            OFFLINE_LIST="${OFFLINE_LIST}
🔴 ${ALIAS} (${MAC}) TIDAK TERDETEKSI"
        fi
    else
        echo "ONLINE: $ALIAS ($MAC) -> $IP"
        if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$IP" > "$LASTIP_FILE"
            if [ "$IP" != "$KNOWNIP" ]; then
                if [ "$AUTO_UPDATE_CONF" = "1" ]; then
                    if update_conf_ip "$MAC" "$IP"; then
                        echo "IP-AUTOUPDATE: $ALIAS conf=${KNOWNIP:-kosong} -> $IP (devices.conf updated)"
                        IP_CHANGED_LIST="${IP_CHANGED_LIST}
🔄 ${ALIAS} IP ${KNOWNIP:-kosong} -> $IP (auto-update)"
                    else
                        echo "IP-BERUBAH: $ALIAS conf=$KNOWNIP ketemu=$IP -> auto-update GAGAL, update manual / reservasi di router"
                    fi
                else
                    echo "IP-BERUBAH: $ALIAS conf=$KNOWNIP ketemu=$IP -> update devices.conf / reservasi di router"
                fi
            fi
        fi
        if [ "$FAIL_COUNT" -ge "$MAX_MISS" ]; then
            RECOVERED_LIST="${RECOVERED_LIST}
🟢 ${ALIAS} (${MAC}) KEMBALI ONLINE ($IP)"
        fi
        echo 0 > "$STATE_FILE"
    fi
done < <(device_lines)

NOTIF=""
[ -n "$OFFLINE_LIST" ] && NOTIF="${NOTIF}Beberapa device offline:${OFFLINE_LIST}"
[ -n "$RECOVERED_LIST" ] && NOTIF="${NOTIF}
Perangkat kembali online:${RECOVERED_LIST}"
if [ "$NOTIFY_IP_CHANGE" = "1" ] && [ -n "$IP_CHANGED_LIST" ]; then
    NOTIF="${NOTIF}
IP berubah (auto-update):${IP_CHANGED_LIST}"
fi

FOUND=$((TOTAL - $(echo "$OFFLINE_LIST" | grep -c "🔴" || true)))
echo "$(date '+%F %T') iface=$IFACE found=$FOUND/$TOTAL" >> "$LOG_FILE"

if [ -n "$NOTIF" ]; then
    MESSAGE="⚠️ Notifikasi cekmac.sh

${NOTIF}

⏰ $(date)
iface=${IFACE}"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MESSAGE}"
fi
