# Alur Termux ke PC

Dokumen ini menjelaskan cara 9Router di Android Termux dikonfigurasi ke PC
Windows, dari awal sampai sinkronisasi pertama berjalan.

Ada dua cara. Yang pertama manual, yang kedua membiarkan HP menuliskan
konfigurasinya. Jalur kedua disarankan karena bridge key itu 64 karakter hex
dan menyalinnya dengan tangan adalah cara yang sangat mudah menghasilkan satu
huruf salah.

---

## 1. Pastikan bridge hidup

Di Termux:

```sh
9router bridge
```

Perintah ini mencetak **bridge key** dan **URL tunnel**, plus perintah siap
pakai untuk PC. Simpan keluarannya.

Kalau 9Router belum menjalankan tunnel, `9router bridge` akan memberi tahu.
9Router mendengarkan di port `20128` di HP, dan tunnel ngrok meneruskan
port itu ke URL publik.

> **URL ngrok free berubah setiap tunnel di-restart.** Ini bukan bug. Lihat
> [gotcha.md](gotcha.md#url-ngrok-yang-berputar).

### Alternatif: mode LAN

Kalau HP dan PC di Wi-Fi yang sama, tunnel ngrok tidak diperlukan sama sekali:

```
http://<IP-HP>:20128
```

Tidak ada ngrok, tidak ada rotasi URL, tidak perlu restart tunnel. Kalau tidak
bisa diakses, cek firewall Windows. Kelolaannya ada di menu `9`.

---

## 2a. Cara manual

Di PC:

```powershell
git clone https://github.com/zuher5/9router-sync
cd 9router-sync
Copy-Item sync-9router.config.example.json sync-9router.config.json
notepad sync-9router.config.json
```

Isi dua baris ini dari `9router bridge`:

```json
{
  "remoteUrl": "https://<NGROK_URL>",
  "bridgeKey": "<64 karakter hex>",
  "defaultModel": "",
  "tools": ["opencode", "omp", "hermes", "claude", "codex"],
  "backupKeep": 5,
  "urlHistory": []
}
```

Lalu:

```powershell
.\sync-9router.bat --cli -WhatIf
.\sync-9router.bat --cli
```

Atau buka menu dan pakai `3` (Ubah pengaturan) kalau lebih suka.

---

## 2b. Cara otomatis: HP menuliskan config-nya

### Menjalankan script di HP

Script-nya di `termux/9router-bridge-export.sh`. Ada dua cara menjalankannya.

**Clone repo di Termux** (kalau `git` belum ada: `pkg install git`):

```sh
git clone https://github.com/zuher5/9router-sync
cd 9router-sync
bash termux/9router-bridge-export.sh
```

**Atau copy satu file saja**, kalau tidak mau clone seluruh repo:

```sh
mkdir -p ~/9router-sync/termux
# salin 9router-bridge-export.sh ke sana lewat file manager atau editor
cd ~/9router-sync
bash termux/9router-bridge-export.sh
```

### Prasyarat

`curl` belum tentu ada di Termux. Script akan memberi tahu dan berhenti dengan
exit code 2 kalau belum ada:

```sh
pkg install curl
```

### Opsi

```sh
bash 9router-bridge-export.sh                    # URL dideteksi dari `9router bridge`
bash 9router-bridge-export.sh --url <URL>        # URL eksplisit
bash 9router-bridge-export.sh --key <HEX>        # bypass file key, untuk uji
bash 9router-bridge-export.sh --out <PATH>       # tujuannya
bash 9router-bridge-export.sh --print            # cetak, tidak menulis file
bash 9router-bridge-export.sh --tools a,b,c      # daftar tool untuk PC
```

Exit code: `0` berhasil, `1` key atau URL tidak ditemukan / bridge menolak,
`2` argumen salah atau prasyarat belum ada.

### Yang terjadi di dalam script

1. Resolve bridge key: `REMOTE_9ROUTER_BRIDGE_KEY` → `NINEROUTER_BRIDGE_KEY` →
   `~/.9router/auth/bridge-key`. Script **tidak pernah** membuat key baru,
   karena HP adalah source of truth dan key yang dikarang di sini cuma akan
   ditolak.
2. Resolve URL tunnel: dari `--url`, atau dari `9router bridge`. Parse output
   adalah kenyamanan, bukan kontrak — kalau formatnya berubah, `--url` tetap
   jalan.
3. Verifikasi dengan `curl` ke `/api/bridge/cli-tools/all-statuses`.
   `200` = key cocok. `401` = tidak cocok, dan script berhenti tanpa menulis
   file, karena menuliskan setup file dengan key yang tidak bisa bekerja hanya
   memindahkan kegagalan ke nanti.
4. Tulis `9sync-setup.local.md`.

### Keluarannya

Default ke `/storage/emulated/0/Download/9sync-setup.local.md`, karena itu
folder yang terjangkau file manager, aplikasi chat, atau kabel USB tanpa
bertarung dengan sandbox Android. Kalau shared storage tidak bisa ditulis,
script jatuh ke `$HOME` dan memberi tahu.

> **File ini mengandung password.** Jangan masuk commit, jangan dikirim ke
> chat yang longgar, jangan di-screenshot, dan **hapus setelah konfigurasi
> selesai**. Namanya diawali `.local` dan sudah masuk `.gitignore` untuk
> alasan itu, tapi `.gitignore` bukan pengganti menghapus file.

---

## 3. Transfer ke PC

Script tidak bisa mengirim file sendiri, jadi pilih salah satu:

| Cara | Catatan |
|---|---|
| Kirim ke diri sendiri (Telegram, WhatsApp) | Paling cepat. File masuk folder unduhan PC. |
| Folder bersama di LAN / Syncthing | Tidak lewat internet sama sekali. |
| Kabel USB / SD card | Mentah, tapi private. |
| **GitHub gist** | **Jangan.** Gist itu publik. |

---

## 4. Import di PC

Sekali jalan:

```powershell
.\sync-9router.bat --cli -SetupFile "<path>\9sync-setup.local.md"
```

Lewati TUI, atau pakai menunya: `.\sync-9router.bat` lalu tekan `I`.

Yang terjadi:

- `remoteUrl` dan `bridgeKey` **selalu** diterapkan — itu yang paling tahu
  HP, dan hanya HP yang bisa tahu
- `defaultModel`, `tools` dan `backupKeep` **tidak** diterapkan kecuali kamu
  minta, supaya daftar tool yang sudah kamu rapikan tidak ditimpa begitu saja
  oleh file yang di-generate
- `urlHistory` dapat URL baru di depan, maksimal 6
- Key yang kerede atau URL yang bukan `http(s)` ditolak, dan config tidak
  disentuh

Untuk melihat dulu tanpa menulis apa pun:

```powershell
.\sync-9router.bat --cli -SetupFile "<path>" -WhatIf
```

### Untuk AI agent

File yang di-generate sudah memuat bagian "Kalau kamu ini AI agent" berisi
langkah-langkah persis, termasukLarangan menulis bridge key ke file lain.
Kalau bingung, kirim `9sync-setup.local.md` ke agent dan bilang: *"konfigurasi
PC ini untuk 9sync"*.

---

## 5. Sync pertama

```powershell
.\sync-9router.bat --cli -WhatIf
```

Baca outputnya. Kalauzewbt yang diharapkan:

```
  opencode   5 -> 5   -1 (provider/model-lama)
  omp        5 -> 5
  hermes     5 -> 5
```

Kalau ada baris `not-installed`, tool itu memang belum ada di PC ini — install
dulu atau keluarkan dari daftar `tools`.

Kalau ada `failed`, **jangan** 계속 ke run berikutnya. Pesan error-nya
menyebut file dan alasannya, dan tidak ada file yang ditulis pada run yang
gagal.

Baris `unchanged` artinya file sudah sama persis dengan yang ada di disk. Itu
hasil yang benar, bukan sync yang gagal.

Setelah yakin:

```powershell
.\sync-9router.bat --cli
```

---

## 6. Rotasi key

Kalau key bocor, atau kamu hanya mau berganti:

```sh
# di Termux
rm ~/.9router/auth/bridge-key
# lalu restart 9Router
```

Key baru dibuat otomatis. Di PC:

```sh
bash termux/9router-bridge-export.sh
```

Lalu import ulang, atau ubah manual lewat menu `3`.

Rotasi tidak mengakhiri URL ngrok yang sekarang, jadi `remoteUrl` juga
perlu dipastikan benar.

---

## Lihat juga

- [bridge-api.md](bridge-api.md) — route API, sumber model, mekanisme auth
- [konfigurasi.md](konfigurasi.md) — format file config tiap tool
- [gotcha.md](gotcha.md) — jebakan yang pernah ditemukan
