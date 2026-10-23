#!/bin/bash
# install.sh - pasang dependency, permission, dan cron untuk cekmac.sh
#
# Pemakaian:
#   sudo ./install.sh              # install dependency + cron
#   sudo ./install.sh --yes        # tanpa konfirmasi
#   sudo ./install.sh --no-install # lewati instalasi paket
#   sudo ./install.sh --no-cron    # lewati pembuatan cron
#   sudo ./install.sh --test       # kirim pesan tes ke Telegram
#
# Aman dijalankan ulang (idempotent). devices.conf TIDAK pernah ditimpa.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/cekmac.sh"
CONF="$SCRIPT_DIR/devices.conf"
CRON_FILE="/etc/cron.d/cekmac"

ASSUME_YES=0
DO_INSTALL=1
DO_CRON=1
DO_TEST=0

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=1 ;;
        --no-install)    DO_INSTALL=0 ;;
        --no-cron)       DO_CRON=0 ;;
        --test)          DO_TEST=1 ;;
        -h|--help)       usage ;;
        *) echo "Opsi tidak dikenal: $1 (pakai --help)" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || die "mode non-interaktif: tambahkan --yes"
    local a
    read -r -p "$1 [y/N] " a
    case "$a" in y|Y|ya|YA) return 0 ;; *) return 1 ;; esac
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "jalankan dengan sudo: sudo $0"
}

# ---------------------------------------------------------------- dependency

have_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    [ -x "/usr/sbin/$1" ] || [ -x "/usr/bin/$1" ]
}

missing_cmds() {
    local c out=""
    for c in bash awk grep sed cut tr date mktemp timeout ip arping ping curl flock arp-scan; do
        have_cmd "$c" || out="$out $c"
    done
    echo "${out# }"
}

install_deps() {
    local pkgs=""
    if command -v apt-get >/dev/null 2>&1; then
        pkgs="arp-scan iputils-arping iputils-ping iproute2 curl cron util-linux"
        log "== apt-get install: $pkgs"
        apt-get update -qq || warn "apt-get update gagal, lanjut coba install"
        DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
    elif command -v dnf >/dev/null 2>&1; then
        pkgs="arp-scan iputils iproute curl cronie util-linux"
        log "== dnf install: $pkgs"
        dnf install -y $pkgs
    elif command -v yum >/dev/null 2>&1; then
        pkgs="arp-scan iputils iproute curl cronie util-linux"
        log "== yum install: $pkgs"
        yum install -y $pkgs
    elif command -v pacman >/dev/null 2>&1; then
        pkgs="arp-scan iputils iproute2 curl cronie util-linux"
        log "== pacman -S: $pkgs"
        pacman -Sy --noconfirm $pkgs
    elif command -v zypper >/dev/null 2>&1; then
        pkgs="arp-scan iputils iproute2 curl cron util-linux"
        log "== zypper install: $pkgs"
        zypper --non-interactive install $pkgs
    elif command -v apk >/dev/null 2>&1; then
        pkgs="arp-scan iputils iproute2 curl util-linux"
        log "== apk add: $pkgs"
        apk add --no-cache $pkgs
    else
        warn "package manager tidak dikenali; install manual: arp-scan arping iproute2 curl cron flock"
        return 1
    fi
}

enable_cron() {
    systemctl enable --now cron 2>/dev/null \
        || systemctl enable --now crond 2>/dev/null \
        || rc-update add crond default 2>/dev/null \
        || true
}

# --------------------------------------------------------------------- files

fix_permissions() {
    local owner group
    owner="${SUDO_USER:-root}"
    group="$(id -gn "$owner" 2>/dev/null || echo "$owner")"

    chmod +x "$SCRIPT"

    # File konfigurasi & log harus tetap bisa diedit user walau cron jalan sebagai root.
    local f
    for f in "$CONF" "$SCRIPT_DIR/cekmac.log" "$SCRIPT_DIR/cekmac-cron.log"; do
        [ -e "$f" ] || continue
        chown "$owner:$group" "$f" 2>/dev/null || true
        chmod 664 "$f" 2>/dev/null || true
    done

    # State + lock milik user, root tetap bisa tulis.
    if [ -d "$SCRIPT_DIR/.state_cekmac" ]; then
        chown -R "$owner:$group" "$SCRIPT_DIR/.state_cekmac" 2>/dev/null || true
        chmod 775 "$SCRIPT_DIR/.state_cekmac" 2>/dev/null || true
    fi
    [ -e "$SCRIPT_DIR/.devices.lock" ] && chmod 666 "$SCRIPT_DIR/.devices.lock" 2>/dev/null || true

    log "== permission: owner=$owner:$group, cekmac.sh executable"
}

# ---------------------------------------------------------------------- cron

external_cron_exists() {
    local f
    {
        crontab -u root -l 2>/dev/null
        cat /etc/crontab 2>/dev/null
        for f in /etc/cron.d/*; do
            [ "$f" = "$CRON_FILE" ] && continue
            [ -f "$f" ] && grep -h . "$f" 2>/dev/null
        done
    } | grep -v '^[[:space:]]*#' | grep -q 'cekmac\.sh'
}

write_cron() {
    if external_cron_exists; then
        warn "sudah ada entri cekmac.sh di cron lain (root crontab / /etc/crontab)."
        warn "Lewati pembuatan $CRON_FILE agar tidak double-run."
        warn "Hapus entri lama dulu, lalu jalankan ulang: sudo $0 --no-install"
        return 0
    fi

    [ -f "$CRON_FILE" ] && cp -a "$CRON_FILE" "$CRON_FILE.bak.$(date +%s)"

    cat > "$CRON_FILE" <<EOF
# cekmac.sh - dibuat oleh install.sh $(date '+%F %T')
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root cd "$SCRIPT_DIR" && flock -n .cekmac.run.lock ./cekmac.sh >> "$SCRIPT_DIR/cekmac-cron.log" 2>&1
EOF
    chown root:root "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    log "== cron: $CRON_FILE (tiap 5 menit, anti-overlap via flock)"
}

# ------------------------------------------------------------------ telegram

telegram_test() {
    local token chat resp
    token="$(sed -n 's/^BOT_TOKEN="\(.*\)"/\1/p' "$SCRIPT" | head -n1)"
    chat="$(sed -n 's/^CHAT_ID="\(.*\)"/\1/p' "$SCRIPT" | head -n1)"
    [ -n "$token" ] && [ -n "$chat" ] || die "BOT_TOKEN / CHAT_ID tidak ditemukan di cekmac.sh"

    log "== tes Telegram ke chat_id=$chat"
    resp="$(curl -s --max-time 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=✅ Tes notifikasi cekmac.sh dari $(hostname) ($(date '+%F %T'))")"

    case "$resp" in
        *'"ok":true'*) log "Telegram OK" ;;
        *) warn "Telegram GAGAL: ${resp:-tidak ada respons}"; return 1 ;;
    esac
}

# --------------------------------------------------------------------- main

log "== cekmac.sh installer =="
log "   folder : $SCRIPT_DIR"
need_root

[ -f "$SCRIPT" ] || die "cekmac.sh tidak ditemukan di $SCRIPT_DIR"
bash -n "$SCRIPT" || die "syntax cekmac.sh error"

if [ "$DO_INSTALL" -eq 1 ]; then
    miss="$(missing_cmds)"
    if [ -n "$miss" ]; then
        log "== dependency kurang:$miss"
        confirm "Install paket yang kurang sekarang?" || die "dibatalkan; install manual lalu jalankan --no-install"
        install_deps || warn "instalasi paket tidak selesai; cek manual"
    else
        log "== semua dependency sudah ada"
    fi
    enable_cron
else
    log "== lewati instalasi paket (--no-install)"
fi

miss="$(missing_cmds)"
[ -n "$miss" ] && warn "masih kurang:$miss (notifikasi bisa gagal / scan kurang akurat)"

[ -f "$CONF" ] || warn "devices.conf belum ada. Copy dari mesin lama (satu folder dengan cekmac.sh)."

fix_permissions

if [ "$DO_CRON" -eq 1 ]; then
    write_cron
else
    log "== lewati cron (--no-cron)"
fi

if ! ip route show default 2>/dev/null | grep -q .; then
    warn "tidak ada default route; cek koneksi/interface"
fi
if ! have_cmd arp-scan; then
    warn "arp-scan tidak ada: script hanya memakai ip neigh (rawan false offline)"
fi

if [ "$DO_TEST" -eq 1 ]; then
    telegram_test || true
fi

log ""
log "Selesai. Ringkas:"
log "  script   : $SCRIPT"
log "  konfig   : $CONF"
log "  log cron : $SCRIPT_DIR/cekmac-cron.log"
log "  log scan : $SCRIPT_DIR/cekmac.log"
log "  state    : $SCRIPT_DIR/.state_cekmac/"
log ""
log "Cek manual : sudo $SCRIPT"
log "Lihat log  : tail -f $SCRIPT_DIR/cekmac-cron.log"
log "Tes notif  : sudo $0 --test --no-install --no-cron"
