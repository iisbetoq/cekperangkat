# cekmac.sh — monitor perangkat via MAC address

Script bash untuk memantau perangkat (HP, IoT, PC) di LAN dan mengirim notifikasi
Telegram saat perangkat hilang atau kembali online. Deteksi berbasis **MAC address**,
bukan IP, jadi tetap benar walau DHCP mengganti IP.

## Kebutuhan

Wajib satu **LAN/VLAN** dengan perangkat yang dipantau — `arp-scan`/ARP tidak
melewati router atau subnet lain. Mesin di VPS/cloud tidak bisa memakai script ini
untuk memantau LAN rumah.

| Komponen | Fungsi |
|---|---|
| `bash` ≥ 4 | script |
| `iproute2` (`ip`) | deteksi interface, `ip neigh` |
| `arp-scan` | scan aktif (root / `CAP_NET_RAW`) |
| `iputils-arping` (`arping`) | bangunkan & verifikasi perangkat sleep |
| `iputils-ping` (`ping`) | fallback bila `arping` tidak ada |
| `curl` | kirim Telegram |
| `cron` | scheduler |
| `util-linux` (`flock`) | lock auto-update & anti-overlap |
| `awk`, `grep`, `sed`, `cut`, `tr`, `timeout` | parsing & utilitas |

## Instalasi cepat

Copy satu folder berisi `cekmac.sh`, `devices.conf`, dan `install.sh` ke mesin baru,
lalu:

```bash
sudo ./install.sh          # install paket + permission + cron tiap 5 menit
sudo ./install.sh --test   # sekalian kirim pesan tes Telegram
```

Opsi lain:

```bash
sudo ./install.sh --yes         # tanpa konfirmasi
sudo ./install.sh --no-install  # paket sudah terpasang manual
sudo ./install.sh --no-cron     # tidak membuat /etc/cron.d/cekmac
```

Setelah install:

```bash
sudo ./cekmac.sh                # coba satu kali
tail -f cekmac-cron.log         # pantau hasil cron
```

Cron yang dibuat (`/etc/cron.d/cekmac`), tiap 5 menit sebagai root:

```
*/5 * * * * root cd /path && flock -n .cekmac.run.lock ./cekmac.sh >> cekmac-cron.log 2>&1
```

Kalau sebelumnya sudah ada entri `cekmac.sh` di root crontab / `/etc/crontab`,
installer tidak menambah entri baru (mencegah double-run).

## devices.conf

Format, satu baris per perangkat:

```
MAC | ALIAS | IP | PORT | MAX_MISS
```

| Kolom | Wajib | Keterangan |
|---|---|---|
| `MAC` | ya | alamat MAC, huruf besar/kecil bebas |
| `ALIAS` | ya | nama di notifikasi, tanpa spasi/`|` |
| `IP` | tidak | untuk unicast wake + fallback TCP. Boleh dikosongkan; **terisi otomatis** saat perangkat pertama terdeteksi |
| `PORT` | tidak | port TCP untuk fallback bila ping/ARP gagal (mis. `80`, `22`, `38599`). Untuk HP umumnya kosong |
| `MAX_MISS` | tidak | jumlah miss sebelum notifikasi. Default `1` (≈5 menit dengan cron 5 menit) |

Contoh menambah perangkat baru — cukup MAC dan nama:

```
aa:bb:cc:dd:ee:ff|HP032
```

Contoh dengan IP tetap dan toleransi sleep 10 menit:

```
aa:bb:cc:dd:ee:ff|HP032|192.168.1.15||2
```

### Auto-update IP

Saat perangkat ONLINE lewat IPv4 dan IP berbeda dari `devices.conf`, script
menulis ulang kolom IP secara atomik (`mktemp` + `mv`, lock `flock`), tanpa
menghapus komentar atau kolom lain. Owner file dipertahankan agar tetap bisa
diedit user meski cron berjalan sebagai root. Backup manual tetap disarankan
untuk perubahan besar.

Matikan auto-update:

```bash
AUTO_UPDATE_CONF=0 ./cekmac.sh
```

Kirim juga notifikasi Telegram saat IP berubah (default hanya log):

```bash
NOTIFY_IP_CHANGE=1 ./cekmac.sh
```

## Cara kerja

1. Unicast `arping` ke IP yang diketahui (membangunkan perangkat sleep).
2. `arp-scan --localnet` 3 pass, jeda 5 detik.
3. Per perangkat: cocokkan MAC di hasil scan.
4. Bila tidak ada: unicast ke IP di conf, lalu IP terakhir terlihat, lalu TCP port.
5. Tidak ketemu → `MISS`. `FAIL_COUNT >= MAX_MISS` → notifikasi offline.
6. Ketemu → `ONLINE`, reset counter; bila sebelumnya offline → notifikasi pulih.

Catatan perilaku:

- Hanya **IPv4 yang fresh** dihitung dari `ip neigh`. Entri `STALE`/`FAILED`/`INCOMPLETE`
  diabaikan karena bisa bertahan lama dan menyebabkan *false ONLINE*; perangkat idle
  tetap diverifikasi lewat unicast `arping`.
- Dengan `MAX_MISS=1`, notifikasi offline dikirim **sekali**, lalu setiap run
  berikutnya selama masih offline (notifikasi berulang tiap ±5 menit).
- Notifikasi pulih dikirim sekali saat kembali online.

## Log & state

| Path | Isi |
|---|---|
| `cekmac.log` | ringkasan tiap run (`found=x/y`) |
| `cekmac-cron.log` | output lengkap cron |
| `.state_cekmac/NAMA.count` | jumlah miss berturut-turut |
| `.state_cekmac/NAMA.lastip` | IPv4 terakhir terlihat |
| `.cekmac.run.lock` | lock anti-overlap cron |
| `.devices.lock` | lock auto-update conf |

Menghapus `.state_cekmac/NAMA.count` akan mereset hitungan offline perangkat tersebut.

## Troubleshooting

**Perangkat offline tapi tetap ONLINE**
Cek `ip neigh | grep -i MAC`. Kalau hanya ada `fe80::... STALE` atau IPv4 `STALE`,
script versi ini sudah mengabaikannya. Pastikan memakai versi terbaru dan
`arp-scan` benar-benar berjalan (lihat log: harus ada output scan, bukan hanya
`ip neigh`).

**`arp-scan` tidak berjalan**
`arp-scan` butuh root atau capability:

```bash
sudo setcap cap_net_raw,cap_net_admin=eip /usr/sbin/arp-scan
```

Paling aman: jalankan lewat cron root seperti bawaan installer.

**`devices.conf` tidak bisa diedit**
Biasanya akibat auto-update lama yang menyisakan file `root:root 600`:

```bash
sudo chown "$USER":"$USER" devices.conf
chmod 664 devices.conf
```

Versi sekarang mempertahankan owner dan chmod otomatis.

**Notifikasi Telegram tidak masuk**
- Tes: `sudo ./install.sh --test --no-install --no-cron`
- Pastikan `BOT_TOKEN` dan `CHAT_ID` benar di `cekmac.sh`.
- Pastikan mesin bisa keluar ke `api.telegram.org:443`.
- Respons error Telegram tidak dicetak karena `curl -s`; jalankan tes di atas untuk melihat respons.

**Perangkat sleep sering false offline**
Naikkan `MAX_MISS` perangkat tersebut (mis. `||2`), isi `PORT` bila ada service TCP,
atau kurangi agresivitas jadwal cron.

**IP terus berubah**
Aktifkan DHCP reservation di router. Auto-update conf hanya membantu, bukan
pengganti reservasi.

## Migrasi ke mesin lain — checklist

1. Mesin baru berada di LAN/VLAN yang sama.
2. Copy `cekmac.sh`, `devices.conf`, `install.sh` ke satu folder.
3. `sudo ./install.sh --test`
4. Pastikan tidak ada entri cron `cekmac.sh` ganda di mesin baru.
5. Cek `tail -f cekmac-cron.log` setelah 5–10 menit.
6. Hapus cron di mesin lama agar tidak ada dua monitor yang saling kirim notifikasi.

> **Keamanan:** `BOT_TOKEN` tersimpan plaintext di `cekmac.sh`. Jangan commit atau
> bagikan file ini ke publik. Kalau bocor, revoke token lewat @BotFather lalu ganti.
