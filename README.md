# 9router-sync

Run [9Router](https://9router.dev) on an Android phone under Termux. Use the
same models on your Windows PC CLI tools — OpenCode, Pi, Hermes, Claude Code,
Codex — without installing 9Router on the PC.

```
   Android / Termux                              Windows PC
+---------------------------+            +---------------------------+
|  9Router                  |            |  OpenCode   opencode.json  |
|  localhost:20128          |            |  Pi         models.json    |
|      |                    |            |  Hermes     config.yaml    |
|  remoteBridge.js          |            |  Claude     settings.json  |
|      |  64-hex bridge key  |            |  Codex      config.toml    |
+-----|--------------------+            +-----------|---------------+
      |  ngrok tunnel                    9router-sync
      +----------> https://<NGROK_URL>/api/bridge/* <---+
                  x-9r-bridge-key: <BRIDGE_KEY>
```

The phone is the source of truth. This tool only reads from it and writes the
result into each PC tool's own config file, leaving everything else in those
files alone.

## Requirements

- Windows PowerShell 5.1 or later (already present on Windows)
- [Node.js](https://nodejs.org/) — only to run the web UI. A sync on its own
  needs nothing but PowerShell.

## Quick start

### 1. On the phone (Termux)

Make sure 9Router is running and get the bridge key:

```sh
9router bridge
```

Copy the **bridge key** (64 hex characters) and your endpoint:

- **Same Wi-Fi (LAN, no tunnel needed):** `http://<PHONE-IP>:20128`
- **Online via Cloudflare Tunnel (free, no signup):**
  ```sh
  pkg install cloudflared
  cloudflared tunnel --url http://127.0.0.1:20128
  ```
  Use the generated `https://<random>.trycloudflare.com` URL.
- **Online via ngrok:** `ngrok http 20128` → `https://<random>.ngrok-free.dev`

### 2. On the PC

```powershell
git clone https://github.com/zuher5/9router-sync
cd 9router-sync
9sync
```

A URL with a token prints in the terminal and the browser opens. Fill in the
endpoint and bridge key, then click **Sync now**.

> The token in the URL is what stops another website in your browser from
> driving this local server. Keep the tab open; the token is valid for as long
> as the command runs.

### Calling it from anywhere

Add the folder to PATH once:

```powershell
[Environment]::SetEnvironmentVariable("Path", `
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$PWD", "User")
```

Restart the terminal, then `9sync` works from any directory.

## The command

| Command | Does |
|---|---|
| `9sync` | Opens the web UI |
| `9sync --cli` | One-shot sync, output in the terminal |
| `9sync --cli -WhatIf` | Preview, writes nothing |
| `9sync --cli -Tools opencode,hermes` | Only those tools |
| `9sync --cli -ListModels` | Show the models the phone would sync, with their source tool |
| `9sync --cli -PickDefault` | Choose which model the tools default to (saves to config, then sync) |
| `9sync --cli -DefaultModel vendor/model` | Default for this run only |

Both paths call the same engine, so the CLI and the browser can never disagree
about what happened.

## Layout

```
engine/           PowerShell. No UI, no dependencies.
  sync.ps1        the engine and its CLI entry point
  setup.ps1       one-time import of the setup file the phone writes
  lib/            core IO + JSON, YAML editing, TOML editing, resolution
  adapters/       one file per tool
web/              the web UI. Node standard library only.
test/             the suite, plus a mock bridge for end-to-end runs
```

`omp` is registered but is not installed here, so it stays out of the tool list
until it is. It keeps working the moment it is.

## Which files get touched

| Tool | File | Install | How it is edited |
|---|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\opencode.json` | `npm i -g @opencode/cli` | provider block rewritten, everything else preserved |
| Pi | `%USERPROFILE%\.pi\agent\models.json` and `settings.json` | `npm i -g @earendil-works/pi-coding-agent` | `providers.9router` in `models.json`, `defaultProvider`/`defaultModel` in `settings.json` |
| Hermes | `%LOCALAPPDATA%\hermes\config.yaml` and `.env` | Hermes app for Windows | `model:` and `providers.9router`; the provider block is created if absent |
| Claude Code | `%USERPROFILE%\.claude\settings.json` | run `claude` once | merge only: `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` |
| Codex | `%USERPROFILE%\.codex\config.toml` | run `codex` once | merge only, section-aware: `base_url`, `api_key`, `model` |
| omp | `%USERPROFILE%\.omp\agent\models.yml` and `config.yml` | `bun install -g @oh-my-pi/pi-coding-agent` | `providers.9router` only; `modelRoles` pins released when stale |

A tool whose file is absent reports `not-installed` and is left alone. The
dashboard lists only what is installed.

## Safety behaviour

- Timestamped backups before every write, `backupKeep` per file retained
- UTF-8 without BOM on write; a BOM is stripped on read
- A file that is not UTF-8 is decoded with its own codepage and written back the
  same way, so an ANSI config is never turned into a corrupted one
- Identical content reports `unchanged` and is neither rewritten nor backed up
- A file is only rewritten if the content actually differs
- If the bridge fails or returns non-JSON, nothing is written at all
- A model that is not in the catalog and has no alias is skipped and reported
- Deleting a model in 9Router removes it from every tool on the next run
- An agent pinned to a model that no longer exists gets unpinned, not deleted:
  the agent keeps its own `description`, `mode` and `tools`
- One failing tool does not stop the others, and the report says what actually
  landed

## Config

`sync-9router.config.json` next to `9sync.cmd`, gitignored:

```json
{
  "remoteUrl": "http://192.168.0.4:20128",
  "bridgeKey": "<64 hex characters>",
  "defaultModel": "",
  "tools": ["opencode", "pi", "hermes", "claude", "codex"],
  "backupKeep": 5,
  "urlHistory": []
}
```

`remoteUrl` and `bridgeKey` ship empty on purpose: the bridge key is a shared
secret that only exists on the phone, and the tunnel URL rotates on every
restart, so neither belongs in a file that is meant to be shared.

The fastest way to fill it in is to let the phone write it:

```sh
# in Termux
bash termux/9router-bridge-export.sh
```

That produces `9sync-setup.local.md`. Copy it to the PC, then:

```powershell
powershell -File .\engine\setup.ps1 -SetupFile <path>\9sync-setup.local.md
```

## Tests

```powershell
.\test\run-tests.ps1     # unit + adapter tests, no network
```

End-to-end runs use a mock bridge, so nothing touches your real configs:

```powershell
node test\mock-bridge.mjs 20999 test-key    # in one window
.\test\e2e.ps1                             # in another
```

The e2e file redirects `%USERPROFILE%` and `%LOCALAPPDATA%` into a temp
directory and aborts if any tool path would fall outside it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No endpoint configured` | Fresh clone | Set the endpoint in Settings, or import the setup file |
| `401` | The key does not match | `9router bridge` on the phone. A bridge key is 64 hex characters; `sk-…` is the inference key and will never work here |
| `No bridge at <url> (404)` | The tunnel URL rotated | Run `9router bridge` again and enter the new URL |
| `Bridge key must be 64 hex characters; got 63` | A character was lost in the paste | Copy it again |
| `Unknown tool: xyz` | A typo in the tool list | Fix it. The sync stops rather than guessing |
| `ngrok blocked …` | The bypass header is missing | Do not remove `ngrok-skip-browser-warning` |
| Port 8787 in use | Another 9sync or app | `set NINESYNC_PORT=8788` |

For anything else, open **Diagnostics** in the UI and copy the output. The
bridge key and API key are masked before anything leaves the machine.

## Docs

- [docs/konfigurasi.md](docs/konfigurasi.md) — file formats, merge rules, arguments
- [docs/bridge-api.md](docs/bridge-api.md) — the bridge endpoints and auth
- [docs/termux.md](docs/termux.md) — phone-side setup
- [docs/gotcha.md](docs/gotcha.md) — failure modes and their causes

## License

MIT. See [LICENSE](LICENSE).