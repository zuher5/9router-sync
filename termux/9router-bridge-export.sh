#!/data/data/com.termux/files/usr/bin/sh
# 9router-bridge-export.sh
#
# Runs on the phone (Termux), not on the PC. Reads the bridge key and the tunnel
# URL, then writes 9sync-setup.local.md: a file a person can read, the PC script
# can import, or an AI agent can follow to configure the PC end to end.
#
# The reason this exists is that the bridge key is 64 hex characters. Having a
# human copy that by hand is a reliable way to end up with one wrong character
# and a 401 that looks like "wrong key" rather than "typo".
#
# Usage:
#   bash 9router-bridge-export.sh                  # auto-detect the URL
#   bash 9router-bridge-export.sh --url <URL>      # explicit URL
#   bash 9router-bridge-export.sh --key <HEX>      # bypass the key file (testing)
#   bash 9router-bridge-export.sh --out <PATH>     # default: shared storage
#   bash 9router-bridge-export.sh --print          # print, write nothing
#
# Exit codes:
#   0  wrote (or printed) the setup file
#   1  key or URL not found, or the bridge rejected the key
#   2  bad arguments, or a prerequisite is missing

set -u

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

URL=""
KEY=""
OUT=""
DO_PRINT=0
TOOLS="opencode,omp,hermes,claude,codex"
BACKUP_KEEP=5

while [ $# -gt 0 ]; do
    case "$1" in
        --url)   URL="${2:-}"; shift 2 ;;
        --key)   KEY="${2:-}"; shift 2 ;;
        --out)   OUT="${2:-}"; shift 2 ;;
        --tools) TOOLS="${2:-}"; shift 2 ;;
        --print) DO_PRINT=1; shift ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "argumen tidak dikenal: $1" >&2
            echo "lihat --help" >&2
            exit 2 ;;
    esac
done

die()  { echo "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# curl is not in the base Termux install, and the verification step is what
# turns a silent typo into an error message, so it is worth failing loudly.
if ! need curl; then
    echo "curl belum ada. Jalankan:" >&2
    echo "    pkg install curl" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Resolve the bridge key
# ---------------------------------------------------------------------------
#
# Same order as getBridgeKey() in app/remoteBridge.js: env var wins, then the
# file, then 9Router generates one. This script never generates one, because the
# phone is the source of truth and a key invented here would simply be rejected.

KEY_SOURCE=""
if [ -z "$KEY" ]; then
    if [ -n "${REMOTE_9ROUTER_BRIDGE_KEY:-}" ]; then
        KEY="$REMOTE_9ROUTER_BRIDGE_KEY"
        KEY_SOURCE="REMOTE_9ROUTER_BRIDGE_KEY"
    elif [ -n "${NINEROUTER_BRIDGE_KEY:-}" ]; then
        KEY="$NINEROUTER_BRIDGE_KEY"
        KEY_SOURCE="NINEROUTER_BRIDGE_KEY"
    elif [ -f "$HOME/.9router/auth/bridge-key" ]; then
        KEY="$(cat "$HOME/.9router/auth/bridge-key")"
        KEY_SOURCE="~/.9router/auth/bridge-key"
    fi
fi
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
# Folded to lowercase here so the file this script writes is byte-identical to
# what the bridge compares against. The receiver uses timingSafeEqual, which is
# case-sensitive, so an uppercase key that passes the hex check below is still a
# 401 on the PC -- and one that only shows up as "wrong key" after a long paste.
KEY="$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')"

if [ -z "$KEY" ]; then
    echo "bridge key tidak ditemukan. Dicoba:" >&2
    echo "  1. \$REMOTE_9ROUTER_BRIDGE_KEY" >&2
    echo "  2. \$NINEROUTER_BRIDGE_KEY" >&2
    echo "  3. ~/.9router/auth/bridge-key" >&2
    echo >&2
    echo "Kalau 9Router sudah jalan, '9router bridge' akan mencetaknya," >&2
    echo "atau file-nya bisa dibuat ulang dengan:" >&2
    echo "    rm ~/.9router/auth/bridge-key   # lalu restart 9Router" >&2
    exit 1
fi

if [ "${#KEY}" -ne 64 ]; then
    die "bridge key harus 64 karakter, yang ketemu ${#KEY} karakter (sumber: ${KEY_SOURCE:-argumen})"
fi

case "$KEY" in
    *[!0-9a-fA-F]*) die "bridge key bukan hex string yang valid" ;;
esac

# ---------------------------------------------------------------------------
# Resolve the tunnel URL
# ---------------------------------------------------------------------------
#
# --url wins. Otherwise take the tunnel URL out of `9router bridge`, which
# prints the ready-to-paste command for the PC. Parsing it is a convenience, not
# a contract: if the wording changes, --url still works.
#
# Which hostname that URL uses is not fixed. ngrok hands out ngrok-free.dev,
# ngrok.io and ngrok-app.dev for ephemeral tunnels, a reserved domain or a custom
# domain is whatever the account owner typed, and Cloudflare prints
# *.trycloudflare.com. So the known list is tried first and a looser shape is the
# fallback, because a reserved domain is the normal case for anyone who set the
# tunnel up once and would rather not re-import a new URL after every reboot.
#
# The fallback skips the hosts ngrok prints for its own dashboard and docs, which
# look exactly like a tunnel URL and would otherwise be picked first. A wrong
# guess is not fatal: the verification step below rejects it and says which URL
# was tried, which is what makes a loose fallback acceptable here.
TUNNEL_HOSTS='ngrok-free\.dev|ngrok\.io|ngrok-app\.dev|ngrok\.app|trycloudflare\.com|loca\.lt|serveo\.net'
NOT_A_TUNNEL='^https://(dashboard\.ngrok\.com|ngrok\.com|www\.ngrok\.com|docs\.ngrok\.com|github\.com|localhost|127\.0\.0\.1)'

URL_SOURCE=""
if [ -z "$URL" ] && need 9router; then
    BRIDGE_OUT="$(9router bridge 2>/dev/null)"

    URL="$(printf '%s' "$BRIDGE_OUT" \
           | grep -oE 'https://[A-Za-z0-9._-]+\.('"$TUNNEL_HOSTS"')' \
           | head -n 1)"
    [ -n "$URL" ] && URL_SOURCE="9router bridge"

    if [ -z "$URL" ]; then
        URL="$(printf '%s' "$BRIDGE_OUT" \
               | grep -oE 'https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' \
               | grep -vE "$NOT_A_TUNNEL" \
               | head -n 1)"
        [ -n "$URL" ] && URL_SOURCE="9router bridge (domain kustom)"
    fi
fi
URL="$(printf '%s' "$URL" | tr -d '[:space:]')"
URL="${URL%/}"

if [ -z "$URL" ]; then
    echo "URL tunnel tidak ditemukan." >&2
    echo >&2
    echo "Cara tercepat, di Termux:" >&2
    echo "    9router bridge" >&2
    echo >&2
    echo "Lalu jalankan ulang dengan URL yang dicetak:" >&2
    echo "    bash 9router-bridge-export.sh --url https://<hostname>" >&2
    exit 1
fi

case "$URL" in
    http://*|https://*) : ;;
    *) die "URL harus diawali http:// atau https://" ;;
esac

# ---------------------------------------------------------------------------
# Verify before writing anything
# ---------------------------------------------------------------------------
#
# all-statuses is the route the PC actually uses first, so it is the right thing
# to probe. 200 means the key matches. 401 means it does not, and writing a
# setup file with a key that cannot work would only move the failure later.

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "x-9r-bridge-key: $KEY" \
        -H "ngrok-skip-browser-warning: true" \
        "$URL/api/bridge/cli-tools/all-statuses" 2>/dev/null)"

case "$CODE" in
    200) : ;;
    401|403)
        echo "bridge menolak key (HTTP $CODE)." >&2
        echo "Key dari ${KEY_SOURCE:-argumen} tidak cocok dengan yang dipakai 9Router." >&2
        echo "Jalankan '9router bridge' lalu ulangi." >&2
        exit 1 ;;
    000)
        echo "tidak bisa menghubungi $URL (timeout atau DNS gagal)." >&2
        echo "Pastikan 9Router jalan dan tunnel ngrok aktif." >&2
        exit 1 ;;
    *)
        echo "bridge menjawab HTTP $CODE (bukan 200) untuk $URL." >&2
        echo "Kalau semua route 404, tunnel-nya kemungkinan baru restart" >&2
        echo "dan URL-nya sudah berganti. Jalankan '9router bridge' lagi." >&2
        echo "Kalau 404 tanpa restart, patch bridge di HP hilang --" >&2
        echo "jalankan '9patch apply' lalu restart 9Router." >&2
        echo "Kalau URL-nya domain kustom dan ini salah duga, ulang dengan:" >&2
        echo "    bash 9router-bridge-export.sh --url https://<hostname>" >&2
        exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Write the setup file
# ---------------------------------------------------------------------------

if [ "$DO_PRINT" -eq 1 ]; then
    TARGET="(stdout)"
else
    if [ -z "$OUT" ]; then
        # Shared storage, because that is reachable from a file manager, a
        # chat app, or a USB cable without fighting Android's app sandbox.
        OUT="/storage/emulated/0/Download/9sync-setup.local.md"
    fi
    mkdir -p "$(dirname "$OUT")" 2>/dev/null
    if [ ! -d "$(dirname "$OUT")" ]; then
        # Termux without the storage permission lands here.
        OUT="$HOME/9sync-setup.local.md"
        echo "shared storage tidak bisa ditulis, pakai \$HOME" >&2
    fi
    TARGET="$OUT"
fi

CREATED="$(date '+%Y-%m-%d %H:%M')"

# The heredoc goes to stdout for --print and to the file otherwise. Picking the
# redirect up front keeps the body itself identical in both modes, so the two
# can never drift apart.
if [ "$DO_PRINT" -eq 1 ]; then
    REDIRECT="/dev/stdout"
else
    REDIRECT="$TARGET"
    : > "$TARGET" || die "gagal menulis $TARGET"
fi

cat > "$REDIRECT" <<EOF
# 9sync - Setup PC

> Dijadwalkan oleh \`9router-bridge-export.sh\` di HP.
> Dibuat: $CREATED
> Endpoint: $URL
> Key dari: ${KEY_SOURCE:-argumen}
> Bridge check: HTTP $CODE

## PENTING: file ini mengandung password

Isinya \`bridgeKey\`, shared secret yang memberi akses baca/tulis ke
konfigurasi 9Router dan memungkinkan orang lain memakai instance kamu
sebagai proxy. Perlakukan seperti password:

- jangan masuk commit
- jangan dikirim ke chat yang longgar
- jangan di-screenshot
- **hapus file ini setelah konfigurasi selesai**

## Konfigurasi

Jangan diedit. PC bisa mengimpornya langsung.

\`\`\`9sync
{
  "remoteUrl": "$URL",
  "bridgeKey": "$KEY",
  "defaultModel": "",
  "tools": [$(printf '%s' "$TOOLS" | sed 's/,/", "/g; s/^/"/; s/$/"/')],
  "backupKeep": $BACKUP_KEEP
}
\`\`\`

## Kalau kamu ini AI agent

Ikuti persis, jangan improvisationasi:

1. \`git clone https://github.com/zuher5/9router-sync\` (lewati kalau sudah ada)
2. \`cd 9router-sync\`
3. Jalankan:
   \`\`\`powershell
   .\\sync-9router.bat --cli -SetupFile "<path ke file ini>"
   \`\`\`
   Script akan menulis \`sync-9router.config.json\` sendiri.
4. **Jangan** menulis bridge key ke file lain. Jangan simpan di notes.
   Jangan \`git add\` file ini.
5. Kalau perlu lihat hasilnya tanpa menulis:
   \`\`\`powershell
   .\\sync-9router.bat --cli -SetupFile "<path>" -WhatIf
   \`\`\`
6. Laporkan apa adanya: jumlah model per tool, tool yang \`skipped\` /
   \`failed\` / \`not-installed\`, dan alasannya. Jangan menyatakan sukses
   kalau ada \`failed\`.

## Kalau manual

\`\`\`powershell
.\\sync-9router.bat
\`\`\`

1. Menu \`I\` - Import setup HP
2. arahkan ke file ini
3. Menu \`2\` - Preview, baca hasilnya
4. Menu \`1\` - Sync

## Verifikasi

Dari HP (Termux), key masih cocok:

\`\`\`sh
curl -s -o /dev/null -w "%{http_code}\\n" \\
  -H "x-9r-bridge-key: \$(cat ~/.9router/auth/bridge-key)" \\
  $URL/api/bridge/cli-tools/all-statuses
\`\`\`

\`200\` = oke, \`401\` = key berubah, jalankan ulang \`9router bridge\`.

Dari PC:

\`\`\`powershell
.\\sync-9router.bat --cli -WhatIf
\`\`\`

## Kalau gagal

| Gejala | Penyebab | Solusi |
|---|---|---|
| \`401\` | key tidak cocok | \`9router bridge\` di HP, import ulang |
| \`401\` padahal key dari \`9router bridge\` | API key (\`sk-…\`) tertukar dengan bridge key | yang dipakai \`bridgeKey\` harus 64 hex, bukan \`sk-…\` |
| \`404\` di semua route | tunnel restart, URL berganti | \`9router bridge\`, import ulang |
| \`404\` di semua route setelah update 9Router | patch bridge hilang | \`9patch apply\` di HP, lalu restart 9Router |
| \`ERR_NGROK_6024\` | interstitial ngrok | script sudah bypass, jangan hapus header |
| \`The remote name could not be resolved\` | \`-Tools a,b\` dipecah cmd | \`-Tools a b\` atau \`-Tools a,b\` |
| semua tool \`not-installed\` | tool-nya belum ada di PC ini | install toolnya, atau kurangi daftar \`tools\` |

Detail lengkap: https://github.com/zuher5/9router-sync/blob/main/docs/gotcha.md
EOF

if [ "$DO_PRINT" -eq 1 ]; then
    echo
    echo "OK  bridge HTTP $CODE  ($URL)"
    echo " ditcet ke stdout, tidak ada file yang ditulis"
else
    chmod 600 "$TARGET" 2>/dev/null
    echo
    echo "OK  bridge HTTP $CODE  ($URL)"
    echo " ditulis: $TARGET"
    echo " chmod 600, tapi shared storage sering mengabaikan itu."
    echo
    echo "_transfer ke PC, lalu:"
    echo "   .\\sync-9router.bat --cli -SetupFile \"<path>\""
    echo
    echo "Kalau bingung, kirim file ini ke AI agent-mu dan bilang:"
    echo "   \"konfigurasi PC ini untuk 9sync\""
fi

exit 0
