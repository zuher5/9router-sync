# Bridge API & Sumber Data

Referensi teknis untuk talking ke 9Router di Android lewat bridge.

---

## 1. Parameter Utama

| Parameter | Nilai | Keterangan |
|---|---|---|
| **Remote Host** | `https://<NGROK_URL>` | Endpoint publik tunnel ngrok dari Termux |
| **Bridge Prefix** | `/api/bridge/*` | Gateway proxy internal ke 9Router localhost |
| **Auth Header** | `x-9r-bridge-key: <BRIDGE_KEY>` | Wajib pada setiap request bridge |
| **Wajib: bypass interstitial** | `ngrok-skip-browser-warning: true` | **Wajib di semua request**, bukan opsional (lihat [gotcha.md](gotcha.md)) |
| **AI Base URL** | `https://<NGROK_URL>/v1` | Endpoint OpenAI-compatible untuk tool di PC |
| **Katalog Model** | `GET /v1/models` | ±1390 model + `capabilities` (ctx, maxOutput, vision, reasoning) |
| **Port lokal** | `20128` | 9Router mendengarkan di sini; dipakai untuk mode LAN |

API key 9Router **tidak di-hardcode** — dibaca dari `GET /api/bridge/keys`,
dengan fallback ke config CLI tool di PC.

> **URL ngrok free berganti tiap tunnel di-restart.** Itu sebabnya ada menu
> `Kelola URL` dan `urlHistory`. Lihat [gotcha.md](gotcha.md).

---

## 2. Route Bridge Lengkap

### A. Status & Konfigurasi CLI Tools

| HTTP Method | Endpoint Bridge | Config Key | Keterangan |
|---|---|---|---|
| `GET` | `/api/bridge/cli-tools/all-statuses` | — | Status + payload config semua tool sekaligus |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/pi-settings` | `config` | Pi (`~/.pi/agent/models.json`) |
| `GET`/`POST`/`PATCH`/`DELETE` | `/api/bridge/cli-tools/opencode-settings` | `config` | OpenCode (`~/.config/opencode/opencode.json`) |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/claude-settings` | `settings` | Claude Code CLI |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/codex-settings` | `config` | OpenAI Codex CLI |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/crush-settings` | `config` | Charm Crush |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/kilo-settings` | `settings` | Kilo Code CLI |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/cline-settings` | `settings` | Cline CLI |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/droid-settings` | `settings` | Factory Droid |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/forge-settings` | `config` | ForgeCode |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/smelt-settings` | `config` | Smelt CLI |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/codewhale-settings` | `config` | CodeWhale |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/grok-build-settings` | `settings` | Grok Build |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/omp-settings` | `config` | Oh My Pi |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/openclaw-settings` | `settings` | Open Claw |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/hermes-settings` | `settings` | Hermes Agent |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/cowork-settings` | `config` | Claude Desktop (Cowork mode) |
| `GET`/`POST`/`DELETE` | `/api/bridge/cli-tools/deepseek-tui-settings` | `settings` | DeepSeek TUI |
| `GET` | `/api/bridge/cli-tools/devin-settings` | — | Status Devin CLI (ada `installUrl`) |
| `GET` | `/api/bridge/cli-tools/jcode` | — | Status jcode (ada pesan install) |

> `devin` dan `jcode` tidak punya key config — hanya status + pesan install.
>_mobile_-independent_: sisanya di-sinkron dari PC.

### B. Metadata Provider & Keys (Read-Only)

| HTTP Method | Endpoint Bridge | Keterangan |
|---|---|---|
| `GET` | `/api/bridge/keys` | Daftar API key aktif (sumber API key untuk sync) |
| `GET` | `/api/bridge/providers` | Ribuan koneksi upstream + `modelLock_*` |
| `GET` | `/api/bridge/models/alias` | Alias model aktif |
| `GET` | `/api/bridge/combos` | Combo model + fallback routing |
| `GET` | `/api/bridge/tunnel/status` | Status tunnel ngrok / tailscale |

### C. Catatan Keamanan (terverifikasi)

Allowlist bridge lebih longgar dari dokumentasi lama. Hasil uji:

| Request | Hasil |
|---|---|
| `/api/bridge/api/settings/database` | `403` (ditolak) |
| `/api/bridge/v1/models` | `403` (ditolak) |
| `/api/bridge/settings` | **`200`** — tidak ada di daftar route, tapi mengembalikan settings internal 9Router |

Isi `/api/bridge/settings` sudah diperiksa: tidak membocorkan API key.
Tetapi memperbesar attack surface, jadi jangan pernah print responsnya.

---

## 3. Auth & Siklus Hidup Bridge Key

Bridge key adalah shared secret 64 karakter hex. Dibuat otomatis oleh
`getBridgeKey()` di `app/remoteBridge.js:62`, **di HP**.

**HP adalah source of truth.** PC tidak pernah membuat key, hanya
menyajukannya. Ini alasan kenapa repo ini tidak menyimpan key sama sekali.

### Urutan resolusi (remoteBridge.js:62-85)

1. Env var `REMOTE_9ROUTER_BRIDGE_KEY` atau `NINEROUTER_BRIDGE_KEY`
   — kalau diisi, mengoverride file.
2. File `~/.9router/auth/bridge-key` (64 byte, mode 600).
3. Belum ada → di-generate `crypto.randomBytes(32).toString("hex")`, lalu
   disimpan. 9Router berikutnya memakai key itu.

### Cara membaca key (di Termux)

```sh
9router bridge                    # cara paling resmi
cat ~/.9router/auth/bridge-key
```

`9router bridge` mencetak key **dan** perintah siap pakai untuk PC, jadi itu
yang dipakai di quick start.

### Verifikasi key

```sh
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "x-9r-bridge-key: $(cat ~/.9router/auth/bridge-key)" \
  https://<NGROK_URL>/api/bridge/cli-tools/all-statuses
```

`200` = valid, `401` = key salah atau tidak cocok.

### Mekanisme auth (remoteBridge.js:160-182)

Bridge receiver membandingkan header dengan `crypto.timingSafeEqual`, jadi
aman dari timing attack. Setelah cocok, path `/api/bridge/*` di-proxy ke
`/api/*` dan `x-9r-cli-token` lokal disuntikkan — itulah kenapa endpoint
local-only seperti `/api/bridge/keys` tetap bisa dipanggil dari luar internet.

### Rotasi

```sh
rm ~/.9router/auth/bridge-key    # lalu restart 9Router
```

Key baru dibuat otomatis. Update `sync-9router.config.json` di PC, atau
jalankan ulang `termux/9router-bridge-export.sh` lalu import hasilnya.

> **Key = password.** Tersimpan di file plaintext, dan punya akses baca/tulis
> ke konfigurasi 9Router plus kemampuan memakai instance kamu sebagai proxy.
> Kalau bocor: rotasi.

---

## 4. Sumber Data Model

Model di PC **tidak** diambil apa adanya dari config Android. Aturannya:

| Data | Sumber | Alasan |
|---|---|---|
| **Model mana** | **semua** tool di `all-statuses` yang punya config berisi blok `9router` | Config tool yang benar-benar dikonfigurasi di 9Router |
| **Metadata model** | `GET /v1/models` → `capabilities` | Nilai di config Android cuma placeholder |

`Resolve-Models` menelusuri setiap properti payload, memeriksa `config` maupun
`settings`, lalu `providers`/`provider` → `9router` → `models`. Tiga bentuk
didukung: array of `{id}`, array of string, dan object map.

Per September 2026 hanya `opencode` dan `pi` yang punya payload; tool
lainnya `null`. Karena pemindaiannya generalize, model yang ditambahkan lewat
tool lain di 9Router akan ikut terbaca tanpa perlu mengubah script.

Bukti nilai di config Android tidak akurat — Airy yang tertulis di sana bisa
jauh lebih kecil dari yang sebenarnya:

```
config Android : <model>  contextWindow=128000   maxTokens=16384
katalog        : <model>  contextWindow=1048576  maxOutput=65536
```

Pemetaan field katalog → config:

| `/v1/models` `capabilities` | omp `models.yml` | opencode `capabilities` |
|---|---|---|
| `contextWindow` | `contextWindow` | — |
| `maxOutput` | `maxTokens` | — |
| `reasoning` | `reasoning` | — |
| `vision` | `input: [text, image]` | `input: ["text","image"]` |
| `tools` | `supportsTools` | `tools` |

### Tambah / hapus model di 9Router

Daftar model **tidak di-hardcode**. Tambah atau hapus di 9Router → run
berikutnya menyesuaikan sendiri, tanpa edit script dan tanpa restart. Tiga
syarat:

1. Model baru harus ada di katalog `/v1/models`. Kalau tidak, dilewati +
   muncul di laporan.
2. Kalau 9Router mengganti nama combo, tambahkan di `$script:ModelAlias`.
3. Default model selalu ditulis ulang ke nilai dari 9Router.

### Alias Model

Kadang ada nama model di config Android yang sudah mati di sisi 9Router, dan
9Router memakai nama lain untuk combo yang sama. `$script:ModelAlias` memetakan
nama lama ke yang baru sebagai jaring pengaman. Tidak ada efek samping kalau
entri-nya tidak terpakai.

### Status healthy per model

Dicek lewat menu `Test model` (smoke test `POST /v1/chat/completions`).

Provider yang kehabisan kredit atau sedang lambat **hanya** ketahuan dari
panggilan nyata — bukan dari config. Itulah alasan menu ini ada. Timeout 40
detik, karena cold start provider tertentu bisa melampaui 25 detik pada
panggilan pertama dan masih sehat pada panggilan berikutnya.

---

## Lihat juga

- [konfigurasi.md](konfigurasi.md) — format file config, aturan merge
- [gotcha.md](gotcha.md) — jebakan yang pernah ditemukan
- [termux.md](termux.md) — alur kerja HP ke PC
