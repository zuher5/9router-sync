# 9router-sync

Run [9Router](https://9router.dev) on an Android phone under Termux. Use the
same models on your Windows PC CLI tools — OpenCode, omp, Hermes, Claude Code,
Codex — without installing 9Router on the PC.

```
   Android / Termux                              Windows PC
+---------------------------+            +---------------------------+
|  9Router                  |            |  OpenCode   opencode.json  |
|  localhost:20128          |            |  omp        models.yml     |
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

| | |
|---|---|
| PC | Windows, PowerShell 5.1 or newer. No modules, no admin, no install step. |
| Phone | 9Router running in Termux, with its bridge reachable (LAN, Cloudflare Tunnel, or ngrok). **No git clone needed on phone.** |
| Optional | A PC tool to sync into. Anything you do not have installed is reported as `not-installed` and skipped. |

`sync-9router.ps1` declares `#Requires -Version 5.1`. It is written against
PowerShell 5.1 behaviour on purpose; see [docs/gotcha.md](docs/gotcha.md) for
the two places where that matters.

## Quick start

### 1. On the phone (Termux)

Make sure 9Router is running (port `20128`). Get the bridge key:

```sh
9router bridge
```

Copy the **bridge key** and your endpoint:
- **Same Wi-Fi (LAN, no tunnel needed):** `http://<PHONE-IP>:20128`
- **Online (Cloudflare Tunnel, free & no signup):**
  ```sh
  pkg install cloudflared
  cloudflared tunnel --url http://127.0.0.1:20128
  ```
  Use the generated `https://<random>.trycloudflare.com` URL.

### 2. On the PC

```powershell
git clone https://github.com/zuher5/9router-sync
cd 9router-sync
.\sync-9router.bat
```

1. Press `3` (Settings) -> paste your **URL** and **Bridge key**.
2. Press `1` (Sync now) -> Done!

---

### Alternative: CLI or Automated Import

<details>
<summary>Click to view CLI commands and Termux export script</summary>

#### Direct CLI
```powershell
# Preview first
.\sync-9router.bat --cli -WhatIf

# Run sync
.\sync-9router.bat --cli
```

#### Export script from phone
If you prefer not to copy the 64-hex key manually:
```sh
# On Termux
bash termux/9router-bridge-export.sh
```
Transfer `9sync-setup.local.md` to PC and run:
```powershell
.\sync-9router.bat --cli -SetupFile <path>\9sync-setup.local.md
```
See **[docs/termux.md](docs/termux.md)** for details.
</details>

## The menu

Run without arguments:

```powershell
.\sync-9router.bat
```

Dashboard on top, menu below. Arrow keys to move, or press the key directly.

| Key | Action |
|---|---|
| `1` | Sync now |
| `2` | Preview (dry run) |
| `3` | Settings — URL, bridge key, default model, tools, backup count |
| `4` | Test connection — is the bridge up, is auth right |
| `5` | Test models — smoke test each one |
| `6` | Validate tool config files — parse and check for dangling pins |
| `7` | Run history — last 20 syncs |
| `8` | Restore a backup |
| `9` | Manage URL — test every known URL, adopt a working one, or switch to LAN |
| `I` | Import setup file from the phone |
| `0` | Quit |

## Command line

```powershell
# everything, all configured tools
.\sync-9router.bat --cli

# preview only
.\sync-9router.bat --cli -WhatIf

# a subset of tools
.\sync-9router.bat --cli -Tools opencode,hermes

# override the default model for this run only
.\sync-9router.bat --cli -DefaultModel provider/model-name

# keep more backups
.\sync-9router.bat --cli -BackupKeep 10

# write a LAN address for this run only
.\sync-9router.bat --cli -RemoteUrl http://192.168.1.42:20128
```

Command-line arguments apply to that run only. They never become new defaults;
`BackupKeep` is the exception, and it only does so when you save it from the
menu.

## Configuration

Nothing personal is in this repository. `remoteUrl` and `bridgeKey` ship empty
on purpose: the bridge key is a shared secret that exists only on the phone,
and the tunnel URL changes every time the tunnel restarts.

| Key | Default | Meaning |
|---|---|---|
| `remoteUrl` | `""` | `https://<NGROK_URL>` or `http://<LAN-IP>:20128` |
| `bridgeKey` | `""` | 64 hex characters, from the phone |
| `defaultModel` | `""` | Empty means follow whatever 9Router currently defaults to |
| `tools` | all five | Which tools to sync |
| `backupKeep` | `5` | Timestamped backups retained per file |
| `urlHistory` | `[]` | Last six tunnels tried, newest first |

`sync-9router.config.json` and `sync-9router.state.json` are gitignored, and so
is `9sync-setup.local.md`. Your key never leaves your machine through git.

### Which files get touched

| Tool | File | Install | How it is edited |
|---|---|---|---|
| OpenCode | `%USERPROFILE%\.config\opencode\opencode.json` | `npm i -g @opencode/cli` | provider block rewritten, everything else preserved |
| omp | `%USERPROFILE%\.omp\agent\models.yml` and `config.yml` | `bun install -g @oh-my-pi/pi-coding-agent` | YAML block surgery, `modelRoles.default` |
| Hermes | `%LOCALAPPDATA%\hermes\config.yaml` | Hermes app for Windows | YAML block surgery, `model:` and `providers.9router` |
| Claude Code | `%USERPROFILE%\.claude\settings.json` | run `claude` once | merge only: `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` |
| Codex | `%USERPROFILE%\.codex\config.toml` | run `codex` once | merge only: `base_url`, `api_key`, `model` |

A tool whose file is absent reports `not-installed` and is left alone. The
dashboard has a `DI PC` column so you can see this at a glance.

### Safety behaviour

- Timestamped backups before every write, `backupKeep` per file retained
- UTF-8 without BOM; a BOM breaks some TOML and JSON parsers
- Identical content reports `unchanged` and is neither rewritten nor backed up
- If the bridge fails or returns non-JSON, nothing is written at all
- A model that is not in the catalog and has no alias is skipped and reported
- Deleting a model in 9Router removes it from every tool on the next run
- An agent pinned to a model that no longer exists gets unpinned, not deleted:
  the agent keeps its own `description`, `mode` and `tools`

## Where the bridge key comes from

A 64 hex character shared secret, generated on the phone by `getBridgeKey()` in
`app/remoteBridge.js`. The phone is the source of truth; the PC only ever
presents it.

Resolution order: `REMOTE_9ROUTER_BRIDGE_KEY`, then `NINEROUTER_BRIDGE_KEY`,
then `~/.9router/auth/bridge-key`, then generated on first run.

Read it with `9router bridge` or `cat ~/.9router/auth/bridge-key`. To rotate,
delete that file and restart 9Router; a new key is generated automatically.

Details, verification and the auth mechanism:
**[docs/bridge-api.md](docs/bridge-api.md)**.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Belum diisi: remoteUrl, bridgeKey` | Fresh clone, nothing configured yet | Run the export script on the phone, or use menu `3` |
| `401` | Key does not match | `9router bridge` on the phone, re-import |
| `404` on every route | Tunnel restarted, URL rotated | `9router bridge`, re-import, or menu `9` |
| `ERR_NGROK_6024` | ngrok interstitial | Already bypassed by the script; do not remove the header |
| `The remote name could not be resolved` | `-Tools a,b` split by cmd | Use `-Tools a b` or `-Tools a,b` |
| Every tool says `not-installed` | Those tools are not on this PC | Install them, or trim the `tools` list |
| Nothing happens on a second run | Content already matches | Working as intended; look for `unchanged` |

Longer explanations: **[docs/gotcha.md](docs/gotcha.md)**.

## Security

The bridge key is a password. Anyone holding it can read and change your
9Router configuration, and can route their own requests through your instance
and consume your quota.

- This repo ships it empty and gitignores your config, on purpose.
- `9sync-setup.local.md` contains it in plaintext. Delete it once you are done.
- Rotate any time: `rm ~/.9router/auth/bridge-key`, restart 9Router, update
  `sync-9router.config.json` on the PC.

## Documentation

| File | Language | Contents |
|---|---|---|
| [docs/termux.md](docs/termux.md) | Indonesian | The phone-to-PC workflow end to end |
| [docs/bridge-api.md](docs/bridge-api.md) | Indonesian | Every `/api/bridge/*` route, model resolution, auth internals |
| [docs/konfigurasi.md](docs/konfigurasi.md) | Indonesian | Config file formats, merge rules, argument handling |
| [docs/gotcha.md](docs/gotcha.md) | Indonesian | URL rotation, ngrok interstitial, UTF-8 corruption |

## License

MIT. See [LICENSE](LICENSE).
