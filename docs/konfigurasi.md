# Konfigurasi

Format file yang dibaca dan ditulis script, aturan merge, dan cara mengoper
argumen.

---

## 1. Lokasi File Tool di Windows

| CLI Tool | Path | Format | Deteksi |
|---|---|---|---|
| **OpenCode** | `$env:USERPROFILE\.config\opencode\opencode.json` | JSON | — |
| **omp** | `$env:USERPROFILE\.omp\agent\models.yml` | YAML | `omp config path` |
| **omp** | `$env:USERPROFILE\.omp\agent\config.yml` | YAML | default model di `modelRoles.default` |
| **Hermes** | `$env:LOCALAPPDATA%\hermes\config.yaml` | YAML | `hermes config path` |
| **Hermes** | `$env:LOCALAPPDATA%\hermes\.env` | KEY=VALUE | `hermes config env-path` |
| **Claude Code** | `$env:USERPROFILE\.claude\settings.json` | JSON | — |
| **Codex CLI** | `$env:USERPROFILE\.codex\config.toml` | TOML | — |

> **Hati-hati dengan `~\.hermes\`.** Script versi lama menulis ke
> `%USERPROFILE%\.hermes\`. **Hermes tidak membaca file-file itu** —
> `hermes config path` dan `hermes config env-path` sama-sama menunjuk ke
> `%LOCALAPPDATA%\hermes\`. File di `~\.hermes\` adalah sisa yang mati.

### Tool yang belum terinstall

Kalau file tool tidak ada, tool itu dilaporkan `not-installed` dan dilewati —
bukan `skipped`, dan tidak ada file yang dibuat. Alasannya: `skipped` berarti
"ada tapi tidak ada yang berubah", sedangkan tool yang belum ada adalah fakta
tentang PC, bukan hasil sync.

Untuk Claude dan Codex, config-nya dibuat oleh tool itu sendiri saat pertama
dijalankan. Jadi jalankan sekali, baru sync lagi.

Dashboard punya kolom `DI PC` supaya ini kelihatan tanpa harus sync dulu.

---

## 2. Format Config yang Dipakai Script

### OpenCode — v2 shape (9Router mengirim v1)

9Router mengirim bentuk v1, OpenCode v2 mengharapkan bentuk lain. Script
mentransformasi saat merge:

| 9Router (v1) | OpenCode v2 |
|---|---|
| `provider` (singular) | `providers` (plural) |
| `npm` | `package` |
| `options` | `settings` |
| `modalities` | `capabilities` |

Merge, bukan tulis ulang. Yang dipertahankan: `mcp`, `agents`,
`default_agent`, dan provider lain.

### Hermes — surgical YAML edit

`config.yaml` berisi puluhan seksi top-level plus provider lain plus
`fallback_providers` plus `_config_version`. Script hanya menyentuh:

- blok `model:` → `default`, `provider`, `base_url`, `api_key`
- blok `providers.<nama>:` → `name`, `base_url`, `key_env`, `model`,
  `default_model`, `discover_models`, dan isi `models:`

Segala lainnya — `agent`, `terminal`, `browser`, `memory`, `kanban`, `gateway`,
`skills`, dan seterusnya — tidak boleh tersentuh.

`.env` hanya satu baris yang boleh berubah: `OPENAI_API_KEY`.

### Claude Code & Codex — merge only

Hanya tiga field yang ditulis, sisanya milik tool:

| Tool | Field yang ditulis |
|---|---|
| Claude Code | `env.ANTHROPIC_BASE_URL`, `env.ANTHROPIC_AUTH_TOKEN` |
| Codex | `base_url`, `api_key`, `model` |

### Referensi model yang menggantung

Kalau model yang sedang di-pin suatu agent dihapus dari 9Router, pin itu tidak
akan resolve — OpenCode menolak model yang tidak ada di
`providers.9router.models`. Script **melepas pinnya**, bukan menghapus
agent-nya:

```
opencode  agents.explorer.model -> 'ghost-model' dilepas, model tidak ada lagi
```

Agent tetap ada dengan `description`, `mode`, dan `tools` utuh, lalu jatuh ke
default global. Yang dilepas hanya pin yang benar-benar menunjuk provider
`9router`.

Perbedaan penting antara dua kategori referensi model:

| Kategori | Contoh | Yang dilakukan |
|---|---|---|
| **Pin ke provider 9Router** | `agents.explorer.model` | Dilepas otomatis, dilaporkan |
| **Pemanggilan `base_url` langsung** | `hermes fallback_providers` | **Dibiarkan**, hanya dilaporkan |

Yang **tidak pernah** disentuh:

- `opencode/big-pickle` di `agents.build` / `agents.plan` — itu provider bawaan
  OpenCode, bukan model 9Router
- `hermes fallback_providers` — pemanggilan `base_url` langsung, melewati
  daftar model tool. Sudah diuji dan masih hidup; menghapusnya otomatis akan
  merusak fallback yang berfungsi

```
Di luar daftar sync, tidak disentuh (base_url langsung):
  hermes    <provider>/<model>
```

### Default model

Default model di setiap tool **selalu** ditulis ulang ke nilai default dari
9Router. `defaultModel` di config hanya jadi override kalau diisi; kosong
berarti ikut 9Router.

---

## 3. Pemakaian

### Launcher

Repo ini menyertakan `9sync.cmd` (shortcut praktis) di samping `sync-9router.bat`:

```bat
.\9sync.cmd           # interaktif (TUI)
.\9sync.cmd --cli     # CLI langsung
```

Agar perintah `9sync` bisa dipanggil langsung dari folder mana pun di terminal:

```powershell
# Jalankan sekali di PowerShell untuk mendaftarkan folder repo ke PATH:
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$PWD", "User")
```

Setelah restart terminal, cukup ketik `9sync` di folder mana pun.

### Menu

```bat
.\sync-9router.bat
```

Dashboard di atas, menu di bawah. Panah navigasi, atau tekan key langsung.

| Tombol | Menu TUI | Fungsi |
|---|---|---|
| `1` | `Sync now` | Tarik model & koneksi dari 9Router |
| `2` | `Preview (dry run)` | Lihat hasilnya tanpa menulis file |
| `3` | `Settings` | Ubah URL, bridge key, default model, tool, jumlah backup |
| `4` | `Test connection` | Uji koneksi bridge & auth API key |
| `5` | `Test models` | Smoke test tiap model, timeout 40 detik |
| `6` | `Validate configs` | Parse YAML/JSON + cek pin menggantung |
| `7` | `Run history` | 20 sync terakhir |
| `8` | `Restore backup` | Kembalikan file dari `.bak` bertimestamp |
| `9` | `Manage URLs` | Uji semua URL, adopsi yang jalan, atau mode LAN |
| `I` | `Import phone setup` | Baca file `9sync-setup.local.md` |
| `0` | `Quit` | Keluar |

### Command line

```powershell
# sync penuh (semua tool yang aktif di config)
.\sync-9router.ps1

# preview, tidak menulis file
.\sync-9router.ps1 -WhatIf

# hanya sebagian tool
.\sync-9router.ps1 -Tools opencode,hermes

# import file setup dari HP
.\sync-9router.ps1 -SetupFile C:\path\to\9sync-setup.local.md

# override default model
.\sync-9router.ps1 -DefaultModel provider/model-name

# jumlah backup yang disimpan
.\sync-9router.ps1 -BackupKeep 10

# abaikan file config, pakai default
.\sync-9router.ps1 -NoConfig
```

Lewati TUI:

```bat
.\sync-9router.bat --cli
.\sync-9router.bat --cli -WhatIf
.\sync-9router.bat --cli -Tools opencode,omp
```

---

## 4. Perbedaan cara mengoper argumen

`cmd` memecah argumen di koma, PowerShell tidak. Dua bentuk ini setara, tapi
jangan campur:

| Konteks | Bentuk yang benar | Yang terjadi kalau salah |
|---|---|---|
| Prompt PowerShell | `.\sync-9router.ps1 -Tools a,b` | — |
| cmd / `.bat` | `.\sync-9router.bat --cli -Tools a b` | `a,b` jadi tiga token, `b` mengikat posisional ke parameter `String` pertama |
| cmd / `.bat` | `.\sync-9router.bat --cli -Tools a,b` | tetap jalan — `.bat` menyambung ulang koma yang dipecah cmd |

Yang berbahaya itu baris kedua. Kalau token sisanya mendarat di
`$RemoteUrl`, seluruh sync diarahkan ke URL sampah. Gejalanya bukan error
yang jujur, tapi `The remote name could not be resolved: 'b'` — seolah
masalahnya jaringan, padahal tidak.

`.bat` sekarang menyambung ulang nama tool dengan koma, jadi bentuk
`-Tools a,b` aman dari cmd. Dan script menolak endpoint yang bukan
`http://`/`https://` dengan exit code 2 plus penjelasan, jadi salah-paste tidak
lagi tampak seperti "sync gagal karena DNS".

Nama tool yang tidak dikenal juga diberi tahu, bukan diam-diam dilewati:

```
[!] Tool tidak dikenal, dilewati: opencod, comp
```

---

## 5. File Settings

| File | Isi | Ditulis oleh |
|---|---|---|
| `sync-9router.config.example.json` | Template, kosong | Repo |
| `sync-9router.config.json` | URL, bridge key, default model, daftar tool, jumlah backup, riwayat URL | Menu `3` dan `I` |
| `sync-9router.state.json` | Hasil run terakhir, status per tool, health per model, 20 riwayat | Setiap sync berhasil |

Keduanya **di-gitignore**. `config.json` berisi bridge key; `state.json` adalah
state mesin yang tidak berguna bagi orang lain.

Identitas dan base URL tetap mengikuti config Android. Yang di-override hanya
`defaultModel` — biarkan kosong untuk ikut 9Router.

Argumen command line berlaku **hanya untuk run itu**, tidak pernah menjadi
default baru. `--cli -Tools opencode,omp` menyinkronkan 2 tool sekali jalan;
daftar tool di `sync-9router.config.json` tetap 5. Yang tersimpan otomatis
dari sebuah run cuma `state.json` dan tambahan `urlHistory` — sisanya milikmu,
diubah lewat menu `3`.

### Kalau config belum ada

Config yang tidak ada bukan error; `sync-9router.config.json` yang tidak bisa
dibaca juga bukan error fatal, karena default adalah titik awal yang
dokumentasikan. YangKtidak bisa dibiarkan kosong adalah `remoteUrl` dan
`bridgeKey`: script berhenti dengan exit code 2 **sebelum** request network
satu pun, dan menunjuk ke `termux/9router-bridge-export.sh`.

Alasan berhenti di awal, bukan membiarkan 401: key kosong akan muncul
seperti "key salah", padahal masalahnya belum diisi.

---

## 6. Perilaku Keamanan

- Backup bertimestamp: `file.20260926-121734.bak`, simpan 5 terakhir per file
- Tulis UTF-8 **tanpa BOM** (BOM merusak sebagian parser TOML/JSON)
- Isi identik → `unchanged`, tidak ditulis, tidak dibackup
- Kalau bridge gagal / respons bukan JSON → **gagal keras**, tidak ada file
  yang ditulis
- Model yang tidak ada di katalog dan tidak punya alias → dilewati + dilaporkan
- Ringkasan akhir per tool: `updated` / `unchanged` / `skipped` /
  `not-installed` / `failed` / `whatif`
- Laporan perubahan: `6 -> 5  -1 (provider/model-lama)` per file, plus daftar
  pin yang dilepas

Tidak ada path absolut yang tertanam di script mana pun, semuanya pakai
`$PSScriptRoot` / `%~dp0`, jadi foldernya bisa dipindah tanpa perlu mengedit
apa pun.

`sync-9router.ps1` sengaja ditulis sebagai library sekaligus entry point.
Kalau di-dot-source, yang terjadi hanya definisi fungsi — tidak ada yang
dieksekusi. CLI memakai `Invoke-Sync9Router`, TUI memanggil fungsi yang sama,
jadi hanya ada satu implementasi sinkronisasi.

---

## Lihat juga

- [bridge-api.md](bridge-api.md) — route API, sumber model, auth
- [gotcha.md](gotcha.md) — jebakan yang pernah ditemukan
- [termux.md](termux.md) — alur kerja HP ke PC
