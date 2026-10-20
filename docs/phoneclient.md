# Panduan Kontrak 9patch & 9Router Phone Client (phoneclient.md)

Dokumen ini adalah spesifikasi kontrak teknis antara **9Router di Android (Termux / 9patch)** dan **9sync di PC**. 

Gunakan panduan ini saat memperbarui atau mem-patch kode 9Router di HP agar sinkronisasi ke PC agent (OpenCode, Pi, Hermes, Oh My Pi, Claude Code, Codex) selalu akurat dan tidak terjadi desync, model hilang, atau model basi bocor kembali.

---

## 1. Arsitektur & Titik Integrasi

9sync di PC berkomunikasi dengan 9Router melalui 3 endpoint utama di Android (port default `20128` atau via tunnel ngrok):

| Endpoint | Method | Peran di 9sync |
|---|---|---|
| `/api/bridge/cli-tools/all-statuses` | `GET` | Membaca daftar model & default aktif dari CLI tools di HP |
| `/api/bridge/keys` | `GET` | Mengambil 9Router API key aktif untuk PC |
| `/v1/models` | `GET` | Katalog model + spesifikasi `capabilities` (ctx, tools, vision, reasoning) |

> **Autentikasi**: Semua request ke `/api/bridge/*` wajib menyertakan header `x-9r-bridge-key: <64-hex-key>`. Untuk tunnel ngrok, wajib header `ngrok-skip-browser-warning: true`.

---

## 2. Kontrak Payload `all-statuses`

Endpoint `GET /api/bridge/cli-tools/all-statuses` mengembalikan JSON objek yang memetakan nama tool ke status & konfigurasinya:

```json
{
  "opencode": {
    "config": { ... }
  },
  "pi": {
    "config": { ... }
  }
}
```

Setiap objek tool dapat menyimpan payload di properti `config` atau `settings`.

### A. Struktur Kunci Provider (`providers` vs `provider`)

9Router di HP menulis konfigurasi tool. Ada dua penamaan yang pernah muncul di ekosistem:
1. `providers` (plural) — standar OpenCode v2 dan Pi `models.json`.
2. `provider` (singular) — format alternatif / custom patch.

**Aturan Presedensi 9sync di PC:**
- **Prioritas 1**: Jika ada `provider.9router.models`, 9sync akan memakai blok ini dan **mengabaikan** `providers` (mencegah kebocoran snapshot lama).
- **Prioritas 2 (Fallback)**: Jika `provider` tidak ada, 9sync membaca `providers.9router.models`.

**Rekomendasi untuk 9patch di HP:**
- Cukup gunakan satu kunci standar yang konsisten: `providers.9router.models`.
- Saat user menghapus model di dashboard HP, **pastikan model tersebut benar-benar dihapus dari file JSON di HP**. Jangan tinggalkan snapshot ganda (misal `provider` baru tapi `providers` lama masih ada).

### B. Format Model List yang Didukung

9sync mendukung 3 representasi daftar model di dalam `9router.models`:

1. **Object Map (OpenCode style)**:
   ```json
   "providers": {
     "9router": {
       "models": {
         "ag/gemini-3.8-flash-high": { "name": "ag/gemini-3.8-flash-high" },
         "xkiro/qwen/qwen3.8-max:free": { "name": "xkiro/qwen/qwen3.8-max:free" }
       }
     }
   }
   ```
2. **Array of Objects (Pi style)**:
   ```json
   "providers": {
     "9router": {
       "models": [
         { "id": "ag/gemini-3.8-flash-high" },
         { "id": "ollama/gpt-oss:120b" }
       ]
     }
   }
   ```
3. **Array of Strings**:
   ```json
   "providers": {
     "9router": {
       "models": ["ag/gemini-3.8-flash-high", "Mocin"]
     }
   }
   ```

### C. Top-Level Default Model & Agent Pins

Selain daftar model di provider, 9Router di HP juga mencatat model default terpilih:
- `opencode.config.model`: misalnya `"9router/ag/gemini-3.8-flash-high"`
- `pi.config.defaultModel` atau `pi.settings.defaultModel`: misalnya `"ag/gemini-3.8-flash-high"`
- `opencode.config.agents.<nama>.model`: pin per-agent (misal `"9router/GratisanCok"`)

9sync membaca field-field ini dan memperlakukannya sebagai **Phone Default**. Jika config lokal PC (`sync-9router.config.json`) mengosongkan `defaultModel: ""`, PC akan otomatis mengikuti model default dari HP ini.

---

## 3. Format Penamaan Model ID (Prefix `9router/`)

- Di dalam **katalog upstream** (`/v1/models`), ID selalu berbentuk murni: `vendor/model` (contoh: `ag/gemini-3.8-flash-high`, `Craft/glm-5.3`, `GratisanCok`).
- Di config CLI tools HP, ID model boleh ditulis dengan prefix `9router/vendor/model` atau tanpa prefix `vendor/model`.
- **9sync menangani prefix secara simetris**:
  - `9router/vendor/model` dan `vendor/model` akan di-deduplikasi menjadi 1 entri model.
  - Model twin ber-prefix otomatis memakai kapabilitas dari katalog jika tersedia.
  - Pin agent ber-prefix tidak akan dilepas (unpin) secara salah.
- Karakter ID seperti tanda titik dua (`:`) pada tag free (misal `xkiro/qwen/qwen3.8-max:free`) didukung penuh, termasuk pada parser YAML Hermes & Oh My Pi.

---

## 4. Spesifikasi Katalog & Capabilities (`/v1/models`)

Setiap item model yang di-serve oleh 9Router di `/v1/models` disarankan menyediakan objek `capabilities`:

```json
{
  "id": "ag/gemini-3.8-flash-high",
  "capabilities": {
    "contextWindow": 1048576,
    "maxOutput": 65536,
    "tools": true,
    "vision": true,
    "reasoning": true
  }
}
```

- Jika suatu field omitted/kosong:
  - `contextWindow` default: `128000`
  - `maxOutput` default: `16384`
  - `tools` default: `true` (kecuali eksplisit diset `false`)
  - `vision` default: `false`
  - `reasoning` default: `false`
- Jika model ada di CLI tool HP tetapi **belum ada di katalog** 9Router (misal model custom/mirror baru), 9sync tetap menyertakannya ke PC (*mirror-as-is*) dengan kapabilitas default dan flag `tools: true`.

---

## 5. Checklist Saat Mengupdate / Re-patch 9Router di Termux

Sebelum rilis atau setelah update source 9Router di HP:

1. [ ] **Bridge Key**: Pastikan key bridge tetap berupa 64-karakter hex lowercase di `~/.9router/` atau environment Termux.
2. [ ] **Status Route**: Pastikan endpoint `/api/bridge/cli-tools/all-statuses` mengembalikan HTTP 200 dengan JSON yang valid.
3. [ ] **Bersih saat Hapus**: Saat menghapus model dari web dashboard HP, pastikan file config CLI tool di Termux (`~/.config/opencode/opencode.json` & `~/.pi/agent/models.json`) langsung diperbarui dan tidak menyisakan salinan di kunci lain.
4. [ ] **Top-level Default Terpelihara**: Pastikan field `model` di config OpenCode HP menunjuk ke model default yang masih aktif di daftar provider.
5. [ ] **Testing Cepat dari PC**:
   Jalankan perintah ini di PowerShell PC untuk memvalidasi:
   ```powershell
   .\9sync.cmd -ListModels
   ```
   Pastikan jumlah model dan nama default yang tampil di PC sama persis dengan yang ada di layar dashboard 9Router HP.
