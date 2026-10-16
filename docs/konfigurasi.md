# Konfigurasi

Format file yang dibaca dan ditulis engine, aturan merge, dan cara mengoper
argumen.

---

## 1. Lokasi File Tool di Windows

| CLI Tool | Path | Format |
|---|---|---|
| **OpenCode** | `$env:USERPROFILE\.config\opencode\opencode.json` | JSON |
| **Pi** | `$env:USERPROFILE\.pi\agent\models.json` | JSON |
| **Pi** | `$env:USERPROFILE\.pi\agent\settings.json` | JSON |
| **Hermes** | `$env:LOCALAPPDATA\hermes\config.yaml` | YAML |
| **Hermes** | `$env:LOCALAPPDATA\hermes\.env` | KEY=VALUE |
| **Claude Code** | `$env:USERPROFILE\.claude\settings.json` | JSON |
| **Codex CLI** | `$env:USERPROFILE\.codex\config.toml` | TOML |
| **omp** | `$env:USERPROFILE\.omp\agent\models.yml` | YAML |
| **omp** | `$env:USERPROFILE\.omp\agent\config.yml` | YAML |

> **Hati-hati dengan `~\.hermes\`.** Script versi lama menulis ke
> `%USERPROFILE%\.hermes\`. **Hermes tidak membaca file-file itu** —
> `hermes config path` dan `hermes config env-path` sama-sama menunjuk ke
> `%LOCALAPPDATA%\hermes\`. File di `~\.hermes\` adalah sisa yang mati.

Path di-resolve dari `$env:USERPROFILE` dan `$env:LOCALAPPDATA` setiap kali
dipakai, bukan sekali saat file dimuat. Ini yang membuat test bisa mengarahkan
seluruh tool ke direktori sementara lewat environment variable.

### Tool yang belum terinstall

Kalau file tool tidak ada, tool itu dilaporkan `not-installed` dan dilewati —
bukan `skipped`, dan tidak ada file yang dibuat. Alasannya: `skipped` berarti
"ada tapi tidak ada yang berubah", sedangkan tool yang belum ada adalah fakta
 tentang PC, bukan hasil sync.

Untuk Claude dan Codex, config-nya dibuat oleh tool itu sendiri saat pertama
dijalankan. Jadi jalankan sekali, baru sync lagi.

Dashboard hanya menampilkan tool yang benar-benar terpasang di PC ini.

---

## 2. Aturan Merge per Tool

Tidak ada file yang ditulis ulang utuh. Yang dipertahankan:

### OpenCode

| Yang ditulis | Yang dipertahankan |
|---|---|
| `providers.9router` (package, settings, models) | provider lain, `mcp`, `agents`, `$schema` |
| `model` | — |
| `agents.<nama>.model` — **dilepas** kalau modelnya hilang | `description`, `mode`, `tools` |

9Router mengirim bentuk v1 (`provider`, `npm`, `options`, `modalities`).
OpenCode v2 mengharapkan bentuk lain. Script mentransformasi saat merge:

| 9Router (v1) | OpenCode v2 |
|---|---|
| `provider` (singular) | `providers` (plural) |
| `npm` | `package` |
| `options` | `settings` |
| `modalities` | `capabilities` |

`package` yang sudah ada di file dipertahankan, jadi adapter yang dipakai user
tidak ditukar diam-diam.

### Pi

| File | Yang ditulis | Yang dipertahankan |
|---|---|---|
| `models.json` | `providers.9router` (`baseUrl`, `apiKey`, `api`, `models`) | provider lain, seluruh key lain |
| `settings.json` | `defaultProvider`, `defaultModel` | sisanya |

### Hermes

`config.yaml` berisi puluhan seksi top-level plus provider lain plus
`fallback_providers` plus `_config_version`. Script hanya menyentuh:

- blok `model:` → `default`, `provider`, `base_url`, dan `key_env` **atau**
  `api_key` (mana yang sudah dipakai file itu)
- blok `providers.<nama>:` → `name`, `base_url`, `key_env`, `model`,
  `default_model`, `discover_models`, dan isi `models:`

Kalau `providers.9router` belum ada, **blok itu dibuat** di dalam blok
`providers:` yang sudah ada. Provider lain tidak di moversebut. Kalau tidak
ada `model:` sama sekali, blok itu dibuat di paling atas.

`discover_models` ditulis sebagai boolean YAML (`false`), bukan string `"false"`.

`.env` hanya satu baris yang boleh berubah: `OPENAI_API_KEY`.

### Claude Code & Codex — merge only

Hanya tiga field yang ditulis, sisanya milik tool:

| Tool | Field yang ditulis |
|---|---|
| Claude Code | `env.ANTHROPIC_BASE_URL`, `env.ANTHROPIC_AUTH_TOKEN` |
| Codex | `base_url`, `api_key`, `model` (tabel top-level) |

Codex memakai TOML yang **sadar section**: `base_url` di dalam
`[model_providers.other]` adalah milik provider itu dan tidak disentuh. Kunci
yang belum ada disisipkan ke section-nya, dan section-nya dibuat kalau perlu —
bukan di akhir file, yang berarti masuk ke section terakhir secara diam-diam.

### omp

| File | Yang ditulis |
|---|---|
| `models.yml` | `providers.9router` saja: `baseUrl`, `apiKey`, `models` |
| `config.yml` | `modelRoles.default`, dan pin role lain yang sudah mati dilepas |

Semua pencarian di `models.yml` dibatasi ke blok `providers.9router`. Provider
yang ditulis lebih dulu di file tidak boleh ikut tertimpa.

---

## 3. Referensi model yang menggantung

Kalau model yang sedang di-pin suatu agent dihapus dari 9Router, pin itu tidak
akan resolve. Script **melepas pinnya**, bukan menghapus agent-nya:

```
opencode  agents.explorer.model -> 'ghost-model' dilepas, model tidak ada lagi
omp       modelRoles.advisor     -> 'ghost-model' dilepas
```

Agent tetap ada dengan `description`, `mode`, dan `tools` utuh, lalu jatuh ke
default global.

Perbedaan penting antara dua kategori referensi model:

| Kategori | Contoh | Yang dilakukan |
|---|---|---|
| **Pin ke provider 9Router** | `agents.explorer.model`, `modelRoles.advisor` | Dilepas otomatis, dilaporkan |
| **Pemanggilan `base_url` langsung** | `hermes fallback_providers` | **Dibiarkan**, hanya dilaporkan |

Yang **tidak pernah** disentuh:

- `opencode/big-pickle` di `agents.build` / `agents.plan` — itu provider bawaan
  OpenCode, bukan model 9Router
- `hermes fallback_providers` — pemanggilan `base_url` langsung, melewati
  daftar model tool

Pin dikenali baik dalam bentuk string (`9router/x`), string berkuot
(`"9router/x"`), maupun objek (`{providerID, model}`).

---

## 4. Status yang dilaporkan

| Status | Arti |
|---|---|
| `updated` | File berubah |
| `unchanged` | Isi file sudah sama persis — tidak ditulis, tidak dibackup |
| `whatif` | `-WhatIf` aktif, tidak ada yang ditulis |
| `skipped` | Ada, tapi tidak ada yang bisa diubah (mis. blok yang dibutuhkan tidak ada) |
| `not-installed` | Tool belum pernah dijalankan di PC ini |
| `failed` | Error saat menulis file ini |

Ketika satu tool punya beberapa file, status yang ditampilkan adalah yang
**paling serius**, bukan yang terakhir ditemukan. Jadi omp yang `models.yml`-nya
ditulis tapi `config.yml`-nya di-skip tetap dilaporkan `updated`.

---

## 5. Argumen

```powershell
# Preview
9sync --cli -WhatIf

# Tool tertentu
9sync --cli -Tools opencode,hermes

# Lihat model yang akan di-sync, lengkap dengan tool sumbernya di HP
9sync --cli -ListModels

# Pilih default model secara interaktif (disimpan ke config, lalu sync)
9sync --cli -PickDefault

# Default model untuk sekali jalan (tidak disimpan)
9sync --cli -DefaultModel vendor/model

# Endpoint dan key untuk sekali jalan
9sync --cli -RemoteUrl http://192.168.0.4:20128 -BridgeKey <64hex>
```

`*` menandai effective default — model yang benar-benar akan dipakai sync
berikutnya. Kalau config kosong, 9Router yang menentukan (model pertama hasil
resolusi). Model yang ada di HP tapi tidak ada di katalog muncul di bagian
Skipped, bukan hilang diam-diam.

Nilai dari command line menang atas file config.

`bridgeKey` dinormalisasi (dipotong whitespace, huruf kecil) di **semua** jalur
yang menerimanya, termasuk `-BridgeKey`. Bridge membandingkan byte-exact dengan
`timingSafeEqual`, jadi huruf besar adalah kunci yang berbeda dan hasilnya
401 yang terbaca seperti "key salah".

Nama tool yang tidak dikenal **menghentikan** sync dengan pesan error. Tidak
ada fallback ke "semua tool" — itu membuat satu ketik salah terlihat seperti
sync yang berhasil.

---

## 6. Failur yang tercatat

Run yang gagal **tetap** masuk riwayat. Kalau hanya sukses yang dicatat,
dashboard indistinguishable antara "belum pernah jalan" dengan "gagal seminggu
terus".

Riwayat tidak diduplikasi: satu run = satu entri, ditulis di satu tempat saja.

---

## 7. Launcher

| Perintah | Untuk |
|---|---|
| `9sync` | Web UI (butuh Node.js) |
| `9sync --cli` | Sync sekali jalan dari terminal |

Untuk memanggil dari folder mana pun, daftarkan folder repo ke PATH sekali:

```powershell
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$PWD", "User")
```

Setelah terminal di-restart, `9sync` bisa dipanggil dari mana saja.

> **Jangan kumpulkan ulang argumen di batch.** `shift` tidak menulis ulang
> `%*`, dan loop `set ARGS=!ARGS! "%~1"` memecah `-Tools opencode,hermes`
> menjadi dua argumen — sehingga hanya tool pertama yang di-sync, tanpa error.
> `9sync.cmd` meneruskan `%*` apa adanya setelah flag-nya dihapus secara tekstual.

---

## 8. keamanan jaringan

Server web hanya bind ke `127.0.0.1`. Selain itu, setiap request harus
menyertakan token yang dicetak di terminal saat server start, dan `Origin` yang
cocok — karena halaman web di browser lain secara teoritis bisa menembak ke
localhost.

Bridge key dan API key tidak pernah dikirim ke browser. UI hanya melihat 4
karakter pertama dan terakhir. Yang disimpan di file config adalah satu-satunya
salinan.

`restore backup` hanya menerima file yang memang dikelola tool ini, dan backup
harus berada di folder yang sama dengan file yang dipulihkan — tanpa itu, cek
tersebut tidak berarti apa-apa.

---

## 9. Encoding

File dibaca dengan decoder yang sesuai dan ditulis kembali dengan encoding yang
sama:

- UTF-8 (BOM dibuang saat baca, tidak ditulis balik)
- windows-1252 untuk file yang bukan UTF-8

File config tool sering ditulis oleh tool lain di codepage ANSI. Membacanya
sebagai UTF-8 akan mengganti byte yang tidak valid dengan U+FFFD, dan rewrite
membIKATKAN karakter pengganti itu permanen di config user.