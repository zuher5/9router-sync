# Panduan Termux ke PC

Setup 9Router dari Android ke Windows PC dalam 2 langkah.

> **HP tidak perlu clone repo ini.** `9router bridge` dan route `/api/bridge/*`
> disediakan oleh patch di HP — baca [Bridge Perlu Patch](#bridge-perlu-patch-di-hp)
> dulu kalau perintah `9router bridge` bilang `not installed`.

---

## Bridge Perlu Patch di HP

`9router bridge` dan seluruh `/api/bridge/*` **bukan bawaan 9Router**. 9Router
resmi tidak punya konsep bridge key, jadi kalau di HP masih 9Router asli,
perintah itu tidak ada dan `/api/bridge/*` balas `404`.

Di HP yang pakai 9Router Termux, bridge disuntik `9patch`. Jadi:

```sh
# 1. cek apakah bridge sudah ada
9router bridge

# 2. kalau "9router is not installed" / command not found:
#    9patch tidak menemukan paket karena namanya bukan `9router`.
#    Arahkan 9patch ke nama paket yang benar, lalu apply.
9patch --help          # cek nama flag untuk menunjuk paket target
9patch apply
```

> **Penting — nama paket.** Kalau 9Router di HP diinstal sebagai fork
> (misalnya `9router-refine`), 9patch secara default mencari paket `9router` dan
> akan bilang tidak ditemukan. Paket yang di-*apply* adalah yang benar-benar
> terpasang:
> ```sh
> npm ls -g --depth=0 | grep 9router
> ```
>
> Jalankan ulang `9router bridge` setelah `9patch apply`. Kalau masih tidak
> ada, restart 9Router.

**Patch hilang setiap update 9Router.** `9patch apply` menambal file yang
sedang terpasang, jadi `npm update` menimpanya. Gejalanya jelas: semua route
balas `404` padahal sebelumnya jalan, dan `9router bridge` tiba-tiba tidak
mencetak apa-apa. Solusinya `9patch apply` lagi lalu restart.

> Ganti `9patch apply` dengan perintah yang SESUAI dengan output `9patch --help`
> di HP kamu. Flag untuk menunjuk paket target berbeda antar versi, dan
> menyebut flag yang salah di sini lebih buruk daripada tidak menyebutnya.

---

## Langkah 1: Di HP (Termux)

1. Pastikan 9Router berjalan (port `20128`).
2. Tentukan koneksi dari PC ke HP:
   - **Satu Wi-Fi (LAN, tanpa internet/tunnel):**
     Cek IP HP di Wi-Fi (`ifconfig`), contoh URL: `http://192.168.1.50:20128`.
   - **Online (Cloudflare Tunnel, gratis & tanpa akun):**
     ```sh
     pkg install cloudflared
     cloudflared tunnel --url http://127.0.0.1:20128
     ```
     Salin URL yang muncul: `https://<random>.trycloudflare.com`.
   - **Online (ngrok):**
     `ngrok http 20128` -> salin URL `https://<random>.ngrok-free.dev`.
3. Ambil bridge key:
   ```sh
   9router bridge
   ```
   Salin **bridge key** (64 hex characters) yang tercetak.

---

## Langkah 2: Di PC (Windows)

```powershell
git clone https://github.com/zuher5/9router-sync
cd 9router-sync
.\sync-9router.bat
```

1. Tekan `3` (`Settings`).
2. Masukkan **URL** dan **Bridge Key** dari Langkah 1.
3. Tekan `1` (`Sync now`). Selesai!

---

## Opsi Lanjutan

### Mode CLI Langsung

```powershell
# Cek preview tanpa menulis file
.\sync-9router.bat --cli -WhatIf

# Sync semua tool yang aktif
.\sync-9router.bat --cli
```

### Export Otomatis dari HP (Script Helper)

Jika tidak ingin menyalin 64 karakter hex secara manual:

1. Di Termux:
   ```sh
   # jalankan script export dari repo
   bash termux/9router-bridge-export.sh
   ```
   Script akan memvalidasi key dan membuat file `9sync-setup.local.md`.
2. Kirim file tersebut ke PC (via chat, shared folder, atau kabel).
3. Di PC:
   ```powershell
   .\sync-9router.bat --cli -SetupFile "<path>\9sync-setup.local.md"
   ```
   Atau buka menu `.\sync-9router.bat` lalu tekan `I` (`Import phone setup`).

---

## Rotasi Bridge Key

Jika key ingin diganti:
```sh
# di Termux
rm ~/.9router/auth/bridge-key
# restart 9Router (key baru otomatis dibuat)
9router bridge
```
Lalu perbarui key di PC lewat menu `3`.

---

## Lihat juga

- [bridge-api.md](bridge-api.md) — route API, sumber model, mekanisme auth
- [konfigurasi.md](konfigurasi.md) — format file config tiap tool
- [gotcha.md](gotcha.md) — jebakan yang pernah ditemukan
