# Gotcha

Jebakan yang sudah ditemukan dan diselesaikan. Semuanya sudah diperbaiki di
script, tapi dicatat di sini supaya tidak masuk lagi.

---

## URL ngrok yang berputar

Domain ngrok free dibuat ulang setiap tunnel di-restart. Gejalanya: semua
route membalas `404`, termasuk root. **Itu bukan bug script.**

Menu `Kelola URL` menyimpan maksimal 6 URL terakhir, mengujinya satu per
satu, lalu menawarkan:

```
[1] https://<NGROK_URL>                       OK      245 ms
[2] https://<URL-LAMA>                        HTTP 404
[3] input URL baru
[4] mode LAN: http://<IP-HP>:20128 (tidak lewat ngrok)
[0] kembali
```

URL yang tidak menjawab tidak akan diambil — konfigurasi lama dipertahankan.

**Mode LAN** menghapus masalah rotasi URL altogether. 9Router mendengarkan di
port `20128`, jadi kalau HP dan PC di Wi-Fi yang sama:

```
http://<IP-HP>:20128
```

Tidak ada ngrok, tidak ada rotasi, tidak perlu restart tunnel. Perlu cek
firewall Windows kalau tidak bisa diakses.

Kalau kamu mengulang `9router bridge` setelah rotasi, remember bahwa key-nya
tidak berubah — hanya URL-nya. Cukup perbarui `remoteUrl`.

---

## ngrok Interstitial

ngrok membalas dengan halaman HTML interstitial (`ERR_NGROK_6024`, ~241 byte)
ke client yang **tidak** mengirim header bypass:

```
tanpa header  -> 200, 241 byte, "You are about to visit ... ERR_NGROK_6024"
dengan header -> 200, JSON asli
```

Karena `Invoke-RestMethod` mengembalikan apa adanya, script versi lama
menerima string HTML, bukan JSON. Akibatnya:

- blok Pi & OpenCode **dilewati diam-diam**
- blok Claude/Codex **tetap menulis** memakai API key
- lalu mencetak `[OK] Connected!` — **hijau palsu**

Header `ngrok-skip-browser-warning: true` sekarang ada di setiap request, dan
respons divalidasi benar-benar JSON sebelum lanjut. Jangan hapus header itu.

---

## Cloudflare Tunnel vs ngrok

Kalau kamu sering terganggu dengan limitasi atau interstitial ngrok, gunakan
**Cloudflare Tunnel (`cloudflared`)** di Termux:

```sh
pkg install cloudflared
cloudflared tunnel --url http://127.0.0.1:20128
```

- **Kelebihan**: Gratis, tanpa akun/signup, dan **tidak ada halaman interstitial** seperti ngrok.
- **Format URL**: `https://<random>.trycloudflare.com`.
- **Sifat**: Seperti halnya ngrok gratis, URL acak ini akan berganti jika tunnel di-restart. Jika butuh domain permanen, gunakan Cloudflare Named Tunnel atau mode LAN.

---

## `Get-Content` merusak file UTF-8

`Get-Content` di Windows PowerShell 5.1 mendekode memakai **codepage ANSI
konsol**, bukan UTF-8. File yang berisi em-dash kembali sebagai tiga karakter
terpisah, lalu ditulis ulang — dan setiap sync menambah satu lapisan mojibake.

Terbukti di `hermes .env`: 26 baris komentar rusak, ukuran file tumbuh
27841 → 28326 → 29623 byte dari tiga kali sync berturut-turut. Satu em-dash
(`U+2014`, tiga byte `E2 80 94`) berubah jadi tiga karakter, lalu setiap sync
membaca ulang tiga karakter itu sebagai lebih banyak byte lagi:

```
sync 1:  U+2014  ->  3 char  ->   9 byte   (27841 -> 28326)
sync 2:  9 byte  ->  5 char  ->  12 byte   (28326 -> 29623)
sync 3:  dan seterusnya, satu lapisan per run
```

Baris yang rusak semuanya komentar `#`, jadi `OPENAI_API_KEY` dan nilainya utuh
— tapi `.env` bukan file yang boleh dibiarkan makin buruk diam-diam setiap kali
sync dijalankan.

Semua pembacaan sekarang lewat `Read-TextUtf8`, yang memakai
`[System.IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)` secara eksplisit.
Line ending juga dinormalisasi ke LF supaya file CRLF tidak ditulis ulang
terus-menerus.

**Kalau perlu memeriksa file config secara manual, pakai Python, bukan
`Get-Content`:**

```powershell
python -c "import yaml; yaml.safe_load(open(r'C:\...\config.yaml', encoding='utf-8')); print('OK')"
```

Atau kalau `PYTHONIOENCODING` perlu diset:

```powershell
$env:PYTHONIOENCODING = 'utf-8'
```

---

## YAML ditulis dengan surgery, bukan parser

Tidak ada YAML parser di Windows PowerShell, jadi script melakukan edit blok
berbasis indent (`Find-YamlBlock`, `Set-YamlValue`, `Replace-YamlBlock`).

Dua jebakan yang sudah pernah menimpa dan harus diingat:

- **PowerShell menyalin array saat bind parameter.** Mengedit `[string[]]$lines`
  di dalam fungsi diam-diam tidak mengubah array pemanggil. Selalu reassign
  hasilnya: `$lines = Set-YamlValue $lines ...`
- **Indent harus benar.** `providers.<nama>` ada di indent 2, jadi key-nya
  indent 4 dan entri model indent 6. Salah indent = YAML rusak.

Karena itu menu `Validasi file config` ada — dia parse semua file dan melaporkan
pin yang menggantung.

---

## Parameter posisional diam-diam menimpa

`powershell -File` **tidak** memecah argumen di koma, dan
`ValueFromRemainingArguments` tidak menangkap sisanya. Argumen posisional
tambahan mengikat ke parameter `[string]` pertama, yaitu `$RemoteUrl`.

Jadi `sync-9router.bat --cli -Tools opencode,hermes` yang salah paste bisa
mengarahkan seluruh sync ke URL sampah, dengan gejala `The remote name could
not be resolved` — yang terlihat seperti masalah jaringan, padahal bukan.

`.bat` sekarang menyambung ulang nama tool dengan koma, dan script menolak
endpoint yang bukan `http(s)` dengan exit code 2 plus penjelasan.

---

## Tool yang belum terinstall bukan "skip"

Tool yang file config-nya tidak ada dilaporkan `not-installed`, bukan
`skipped`. Alasannya: pada clone yang baru, omp/hermes/claude/codex memang
belum terinstall, dan kalau semuanya dilaporkan `skipped` hasilnya terlihat
seperti "sync tidak berhasil apa-apa" — padahal itu kondisi normal.

`skipped` berarti "file ada, tapi tidak ada yang perlu diubah". Status baru
`not-installed` berarti fakta tentang PC. Bedanya penting waktu membaca
laporan.

---

## Variabel string di dalam string

`$($cfg.bridgeKey).Substring(0, 8)` melempar exception kalau key-nya kosong,
dan kosong adalah default di repo ini. Dashboard sekarang pakai
`Format-BridgeKey`, yang panjangnya dijepit dan menampilkan `(belum diisi)`.

Hal serupa: backtick adalah karakter escape di dalam string PowerScript
berkutip dua. Pesan error yang memuat ``` ```9sync ``` harus ditulis dengan
stringberkutip satu dan konkatenasi, kalau tidak dua pertiga fence-nya
dimakan.

---

## Lihat juga

- [bridge-api.md](bridge-api.md) — route API, sumber model, auth
- [konfigurasi.md](konfigurasi.md) — format file config, aturan merge
- [termux.md](termux.md) — alur kerja HP ke PC
