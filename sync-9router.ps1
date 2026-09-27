<#
.SYNOPSIS
  9Router CLI Tools Synchronizer for Windows PC.
  Mirrors the model list and connection settings configured in Android 9Router
  (Termux) into the CLI tools installed on this PC, over the ngrok bridge.

.DESCRIPTION
  The model list is taken from the CLI tool configs registered in 9Router.
  Every tool in the bridge payload is scanned, so a model added through any of
  them (pi, opencode, omp, ...) is picked up. Per-model metadata (context
  window, max output, reasoning, vision) is read from the /v1/models catalog,
  because the values embedded in the tool configs are placeholders.

  Nothing personal ships in this file. remoteUrl and bridgeKey default to
  empty on purpose: the bridge key is a shared secret that lives only on the
  phone running 9Router, and publishing it would hand anyone read/write access
  to that instance. Fill it in with -RemoteUrl/-BridgeKey for a single run,
  or copy sync-9router.config.example.json to sync-9router.config.json and
  edit that. sync-9router.config.json is gitignored.

  The quickest way to configure a PC is to let the phone write the file for
  you: run termux/9router-bridge-export.sh in Termux, transfer the resulting
  9sync-setup.local.md to the PC, then pass it with -SetupFile.

  Nothing is overwritten wholesale: each tool's own settings are preserved and
  only the 9Router-owned fields are rewritten.

  Model references that point at the 9router provider but no longer exist are
  unpinned, so deleting a model in 9Router cannot leave an agent pointing at a
  model OpenCode will refuse to resolve. The agent itself is kept.

  This file is both a CLI entry point and a library. Dot-sourcing it defines
  Invoke-Sync9Router and the config helpers without running anything.

.EXAMPLE
  .\sync-9router.ps1
.EXAMPLE
  .\sync-9router.ps1 -Tools opencode,omp -WhatIf
.EXAMPLE
  .\sync-9router.ps1 -SetupFile C:\path\to\9sync-setup.local.md
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RemoteUrl = "",
    [string]$BridgeKey = "",
    [string[]]$Tools = @(),
    [string]$DefaultModel = "",
    [ValidateRange(1, 50)]
    [int]$BackupKeep = 0,
    [string]$ConfigPath = "",
    [string]$SetupFile = "",
    [switch]$NoConfig
)

$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$__dotSourced = ($MyInvocation.InvocationName -eq '.')

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:ScriptRoot = if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { $PSScriptRoot }
$script:ConfigDefaults = @{
    # Empty on purpose. See the .DESCRIPTION above: the bridge key is a secret
    # that only exists on the phone, and the tunnel URL rotates on every
    # restart, so neither belongs in a file that is meant to be shared.
    remoteUrl   = ""
    bridgeKey   = ""
    tools       = @("opencode", "omp", "hermes", "claude", "codex")
    defaultModel = ""      # empty = follow whatever 9Router has
    backupKeep  = 5
    urlHistory  = @()
}
$script:AllTools = @("opencode", "omp", "hermes", "claude", "codex")

# Model ids that 9Router has renamed, mapped old id -> current id. A tool config
# can still carry the old id, and the catalog lookup happens before the alias is
# ever needed, so the rename has to be resolved first.
#
# Empty by default because a fresh install has nothing renamed yet. When a model
# shows up as skipped because the catalog says model_not_found, and 9Router
# renamed rather than deleted it, add the pair here:
#
#   $script:ModelAlias = @{ "old-id" = "current-id" }
#
$script:ModelAlias = @{}

$script:BaseUrl = ""
$script:ApiBase = ""
$script:ApiKey = ""
$script:Models = @()
$script:Report = @()
$script:Changes = @()
$script:Dangling = @()
$script:OutOfSync = @()
$script:Cmd = $PSCmdlet
$script:Quiet = $false
$script:BackupKeep = 5
$script:Result = $null

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Info([string]$m)    { if (-not $script:Quiet) { Write-Host "[*] $m" -ForegroundColor Cyan } }
function Write-Success([string]$m) { if (-not $script:Quiet) { Write-Host "[OK] $m" -ForegroundColor Green } }
function Write-Warn([string]$m)    { if (-not $script:Quiet) { Write-Host "[!] $m" -ForegroundColor Yellow } }
function Write-Err([string]$m)     { if (-not $script:Quiet) { Write-Host "[X] $m" -ForegroundColor Red } }
function Write-Detail([string]$m)  { if (-not $script:Quiet) { Write-Host "    $m" -ForegroundColor DarkGray } }

function Add-Report([string]$tool, [string]$path, [string]$status, [string]$detail) {
    $script:Report += [pscustomobject]@{ Tool = $tool; Path = $path; Status = $status; Detail = $detail }
}

function Add-Change([string]$tool, [string]$path, [string[]]$before, [string[]]$after) {
    $b = @{}; foreach ($m in $before) { if ($m) { $b[$m] = $true } }
    $a = @{}; foreach ($m in $after)  { if ($m) { $a[$m] = $true } }
    $removed = @($before | Where-Object { $_ -and -not $a.ContainsKey($_) })
    $added   = @($after  | Where-Object { $_ -and -not $b.ContainsKey($_) })
    $script:Changes += [pscustomobject]@{
        Tool = $tool; Path = $path
        Before = @($before | Where-Object { $_ }).Count
        After  = @($after  | Where-Object { $_ }).Count
        Added = $added; Removed = $removed
    }
}

# ---------------------------------------------------------------------------
# Config file
# ---------------------------------------------------------------------------

function Get-Sync9RouterConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    return (Join-Path $script:ScriptRoot "sync-9router.config.json")
}

function Get-Sync9RouterStatePath {
    return (Join-Path $script:ScriptRoot "sync-9router.state.json")
}

# The bridge receiver compares the key with crypto.timingSafeEqual, which is
# byte-exact, so an uppercase hex key is a *different* key and comes back as a
# bare 401 that reads like "wrong key". A key can reach the PC uppercase from an
# env var, from a copy-paste out of a terminal, or from an editor with
# autocapitalize on, so every path that accepts one folds it here once instead
# of at each comparison.
function Resolve-BridgeKey([string]$key) {
    return "$key".Trim().ToLowerInvariant()
}

# A remoteUrl without a scheme still reaches 9Router, because Invoke-WebRequest
# quietly assumes http for a bare host:port. It is then written verbatim into
# every tool config, where nothing makes that assumption and the tool simply
# cannot connect. So the mistake is caught here, where the message can still
# name the fix, rather than in five tool configs that all fail at once.
function Test-RemoteUrlScheme([string]$url) {
    return ("$url".Trim() -match '^https?://')
}

# Reads sync-9router.config.json over the built-in defaults. A missing or
# corrupt file is not fatal: the defaults are the documented starting point, and
# a broken config should not stop someone from syncing.
function Get-Sync9RouterConfig {
    $cfg = @{}
    foreach ($k in $script:ConfigDefaults.Keys) { $cfg[$k] = $script:ConfigDefaults[$k] }

    $path = Get-Sync9RouterConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Read-TextUtf8 $path
            $j = $raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($p.Name -eq "urlHistory") {
                    $cfg["urlHistory"] = @($p.Value | Where-Object { $_ })
                } else {
                    $cfg[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-Warn "Config tidak bisa dibaca ($($_.Exception.Message)), memakai default."
        }
    }

    # Normalized on read rather than trusted as written. A hand-edited config is
    # where a trailing slash, a stray space, or an uppercased key creeps in, and
    # each of those is trivial to fix here and expensive to diagnose later from a
    # 401 or from a tool that will not connect.
    if ($cfg["remoteUrl"]) { $cfg["remoteUrl"] = "$($cfg["remoteUrl"])".Trim().TrimEnd("/") }
    if ($cfg["bridgeKey"]) { $cfg["bridgeKey"] = Resolve-BridgeKey $cfg["bridgeKey"] }
    $cfg["urlHistory"] = @($cfg["urlHistory"] | Where-Object { $_ } |
                          ForEach-Object { "$_".Trim().TrimEnd("/") })
    return $cfg
}

function Save-Sync9RouterConfig($cfg) {
    $path = Get-Sync9RouterConfigPath
    $out = [ordered]@{
        remoteUrl    = $cfg.remoteUrl
        bridgeKey    = $cfg.bridgeKey
        defaultModel = $cfg.defaultModel
        tools        = @($cfg.tools)
        backupKeep   = [int]$cfg.backupKeep
        urlHistory   = @($cfg.urlHistory)
    }
    # Same 2-space writer as the tool configs, so these files stay diff-friendly
    # and keep a stable key order across runs.
    $json = (ConvertTo-JsonText $out) + "`n"
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Locates the tool config each tool reads, so the TUI can tell "not installed
# on this PC" apart from "installed but nothing to change". A tool that is
# absent is a normal state, not a sync failure, and reporting it as `skipped`
# made a fresh clone look like it had done nothing at all.
$script:ToolPaths = [ordered]@{
    opencode = { Join-Path $env:USERPROFILE ".config\opencode\opencode.json" }
    omp      = { Join-Path $env:USERPROFILE ".omp\agent\models.yml" }
    hermes   = { Join-Path $env:LOCALAPPDATA "hermes\config.yaml" }
    claude   = { Join-Path $env:USERPROFILE ".claude\settings.json" }
    codex    = { Join-Path $env:USERPROFILE ".codex\config.toml" }
}

function Get-ToolPresence {
    $out = [ordered]@{}
    foreach ($t in $script:AllTools) {
        $p = ""
        if ($script:ToolPaths.Contains($t)) { $p = & $script:ToolPaths[$t] }
        $out[$t] = [pscustomobject]@{
            Tool     = $t
            Path     = $p
            Exists   = [bool]($p -and (Test-Path -LiteralPath $p))
        }
    }
    return $out
}

# Reads a 9sync-setup.local.md produced by termux/9router-bridge-export.sh and
# returns the settings block it carries. The file is markdown so a person can
# read it, but the block inside is the same JSON shape as the config file, so
# the phone can write it and the PC can consume it without a second format.
function Read-SetupFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "File setup tidak ditemukan: $path"
    }
    $raw = Read-TextUtf8 $path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "File setup kosong: $path"
    }
    # Fenced block tagged `9sync`. The closing fence may be indented or carry
    # trailing spaces, so match on the tag and the fence independently.
    $m = [regex]::Match($raw, '(?ms)^[ \t]*```[ \t]*9sync[ \t]*\r?\n(.*?)^[ \t]*```')
    if (-not $m.Success) {
        # Single-quoted: a backtick is the escape character inside a double-quoted
        # PowerShell string, which would eat two thirds of the fence marker.
        throw ('Blok ```9sync tidak ada di ' + $path + '. File ini harus dibuat oleh 9router-bridge-export.sh di Termux.')
    }
    try {
        $j = $m.Groups[1].Value | ConvertFrom-Json
    } catch {
        throw ('Blok ```9sync di ' + $path + ' bukan JSON yang valid: ' + $_.Exception.Message)
    }
    return $j
}

# Validates a candidate config and reports what is wrong in the user's terms.
# Returns a list of problem strings; empty means usable.
function Test-SetupValues($setup) {
    $problems = @()
    $url = "$(if ($setup.PSObject.Properties['remoteUrl']) { $setup.remoteUrl })".Trim()
    $key = Resolve-BridgeKey "$(if ($setup.PSObject.Properties['bridgeKey']) { $setup.bridgeKey })"

    if (-not $url) {
        $problems += "remoteUrl kosong. URL tunnel ngrok atau http://<IP-LAN>:20128 wajib diisi."
    } elseif ($url -notmatch '^https?://') {
        $problems += "remoteUrl harus diawali http:// atau https://, bukan '$url'."
    }

    if (-not $key) {
        $problems += "bridgeKey kosong. Jalankan '9router bridge' di Termux lalu jalankan ulang script export."
    } elseif ($key -notmatch '^[0-9a-f]{64}$') {
        # Length is reported rather than the value, so a wrong paste does not
        # end up echoed into a log or a screenshot. A length that is off by one
        # or two is nearly always a dropped character in a copy-paste, not a
        # rotated key, and those two look identical from the outside.
        $problems += "bridgeKey harus 64 karakter hex, yang diimpor $($key.Length) karakter. Panjang yang meleset biasanya berarti ada karakter yang hilang saat copy-paste."
    }
    return $problems
}

# Applies a setup block on top of an existing config. remoteUrl and bridgeKey
# are what the phone is authoritative about, so they always land. The rest is
# a suggestion: overwriting a hand-tuned tool list because a generated file
# said `tools` would be rude, so those need -Force.
function Import-Sync9RouterSetup([CmdletBinding(SupportsShouldProcess)][string]$path, [switch]$Force) {
    $setup = Read-SetupFile $path
    $problems = Test-SetupValues $setup
    if ($problems.Count) {
        throw ("File setup tidak bisa dipakai:`n  - " + ($problems -join "`n  - "))
    }

    $cfg = Get-Sync9RouterConfig
    $url = "$($setup.remoteUrl)".Trim().TrimEnd('/')
    $key = Resolve-BridgeKey "$($setup.bridgeKey)"

    $changes = @()
    if ("$($cfg.remoteUrl)".Trim().TrimEnd('/') -ne $url) {
        $changes += "remoteUrl: '$($cfg.remoteUrl)' -> '$url'"
    }
    if ("$($cfg.bridgeKey)".Trim() -ne $key) {
        $changes += "bridgeKey: diganti (key baru dari HP)"
    }
    $cfg["remoteUrl"] = $url
    $cfg["bridgeKey"] = $key

    $applied = @("remoteUrl", "bridgeKey")
    if ($Force) {
        foreach ($k in @("defaultModel", "tools", "backupKeep")) {
            if ($setup.PSObject.Properties[$k]) { $cfg[$k] = $setup.$k; $applied += $k }
        }
    }

    # The new tunnel goes to the front of the history so a later "try every
    # known URL" starts from the one that is most likely to be alive.
    $hist = @($cfg.urlHistory | Where-Object { $_ -and $_ -ne $url })
    $cfg["urlHistory"] = @($url) + $hist
    if ($cfg.urlHistory.Count -gt 6) { $cfg["urlHistory"] = @($cfg.urlHistory)[0..5] }

    $path2 = Get-Sync9RouterConfigPath
    if ($PSCmdlet.ShouldProcess($path2, "Menulis config dari file setup")) {
        Save-Sync9RouterConfig $cfg | Out-Null
    }
    return [pscustomobject]@{
        ConfigPath   = $path2
        Written      = $true
        Applied      = $applied
        Changes      = $changes
        HadChange    = ($changes.Count -gt 0)
        RemoteUrl    = $url
        Tools        = @($cfg.tools)
        BackupKeep   = [int]$cfg.backupKeep
    }
}

function Get-Sync9RouterState {
    $path = Get-Sync9RouterStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ lastRun = $null; perTool = @{}; modelHealth = @{}; log = @() }
    }
    try {
        $j = (Read-TextUtf8 $path) | ConvertFrom-Json
        if (-not $j.PSObject.Properties.Name -contains "lastRun") { $j | Add-Member -NotePropertyName lastRun -NotePropertyValue $null -Force }
        if (-not $j.PSObject.Properties.Name -contains "perTool") { $j | Add-Member -NotePropertyName perTool -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not $j.PSObject.Properties.Name -contains "modelHealth") { $j | Add-Member -NotePropertyName modelHealth -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not $j.PSObject.Properties.Name -contains "log") { $j | Add-Member -NotePropertyName log -NotePropertyValue @() -Force }
        return $j
    } catch {
        return [pscustomobject]@{ lastRun = $null; perTool = @{}; modelHealth = @{}; log = @() }
    }
}

function Save-Sync9RouterState($state) {
    $path = Get-Sync9RouterStatePath
    $json = (ConvertTo-JsonText $state) + "`n"
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Records what a run did, so the TUI dashboard can show it without having to be
# the one that ran the sync. Called from Invoke-Sync9Router, which means the CLI
# keeps the dashboard current too.
function Record-SyncRun($Config, $result) {
    try {
        $state = Get-Sync9RouterState
        $now = (Get-Date).ToString("MM-dd HH:mm")

        $perTool = [pscustomobject]@{}
        foreach ($t in @("opencode", "omp", "hermes", "claude", "codex")) {
            $rows = @($result.Rows | Where-Object { $_.Tool -eq $t })
            if ($rows.Count -eq 0) { continue }
            $st = "unchanged"
            foreach ($r in $rows) {
                if ($r.Status -eq "failed") { $st = "failed"; break }
                if ($r.Status -eq "skipped") { $st = "skipped" }
                # not-installed is a fact about the PC, not an outcome of the
                # sync, so it only shows when nothing better happened. Without
                # this a tool that is simply absent would be reported as
                # unchanged, which is a claim that was never verified.
                if ($r.Status -eq "not-installed" -and $st -eq "unchanged") { $st = "not-installed" }
                if ($r.Status -eq "updated") { $st = "updated" }
                if ($r.Status -eq "whatif")  { $st = "whatif" }
            }
            $count = 0
            foreach ($c in $result.Changes) { if ($c.Tool -eq $t) { $count = $c.After } }
            $perTool | Add-Member -NotePropertyName $t -NotePropertyValue ([pscustomobject]@{
                status = $st; modelCount = $count; at = $now
            }) -Force
        }

        $state.perTool = $perTool
        $state.lastRun = [pscustomobject]@{
            at           = (Get-Date).ToString("s")
            status       = $(if ($result.Ok) { "ok" } else { "fail" })
            endpoint     = $result.Endpoint
            modelCount   = $result.ModelIds.Count
            defaultModel = $result.DefaultModel
            detail       = $(if ($result.Ok) { "" } else { $result.Error })
        }

        $entry = [pscustomobject]@{
            at      = (Get-Date).ToString("s")
            ok      = [bool]$result.Ok
            models  = $result.ModelIds.Count
            default = $result.DefaultModel
            note    = $(if ($result.Ok) { "$($result.ModelIds.Count) model" } else { $result.Error })
        }
        $log = @($entry) + @($state.log)
        if ($log.Count -gt 20) { $log = $log[0..19] }
        $state.log = $log

        Save-Sync9RouterState $state

        # Only the URL history is touched, and it is read back from disk first.
        # Saving the whole $Config here would promote a one-off command line
        # override such as -Tools opencode,omp into the new persisted default.
        $u = "$($Config.remoteUrl)".TrimEnd("/")
        if ($u) {
            $onDisk = Get-Sync9RouterConfig
            $h = @(@($onDisk.urlHistory | Where-Object { $_ -and "$_".TrimEnd("/") -ne $u }))
            $onDisk["urlHistory"] = @($u) + $h
            if ($onDisk.urlHistory.Count -gt 6) { $onDisk["urlHistory"] = @($onDisk.urlHistory)[0..5] }
            Save-Sync9RouterConfig $onDisk | Out-Null
        }
    } catch {
        # A state file that cannot be written must never turn a good sync into a
        # failed one.
        if (-not $script:Quiet) { Write-Warn "State tidak bisa disimpan: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# ngrok answers clients that omit this header with an HTML interstitial
# (ERR_NGROK_6024) instead of the payload, which turns every response into a
# plain string and makes the whole sync look like it succeeded.
function Get-BridgeHeaders([string]$key) {
    return @{
        "x-9r-bridge-key"            = $key.Trim()
        "ngrok-skip-browser-warning" = "true"
        "Accept"                     = "application/json"
    }
}

function Get-BridgeJson([string]$path, [string]$bridgeKey) {
    $uri = "$script:BaseUrl/api/bridge/$path"
    $resp = $null
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers (Get-BridgeHeaders $bridgeKey) -UseBasicParsing -TimeoutSec 25
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 401) { throw "Bridge key ditolak (401) saat requesting $path." }
        if ($code -eq 403) { throw "Akses ditolak (403) saat requesting $path." }
        if ($code -eq 404) { throw "Bridge tidak ada di $script:BaseUrl (404). URL ngrok kemungkinan sudah rotasi - buka Sync > Kelola URL." }
        throw "Gagal contacting bridge ($path): $($_.Exception.Message)"
    }

    $body = [string]$resp.Content
    if ($body -match 'ERR_NGROK') {
        throw "ngrok memblokir request ke $path (interstitial ERR_NGROK). Header bypass hilang?"
    }
    if ($body.TrimStart() -notmatch '^\{') {
        throw "Respons $path bukan JSON (dapat $($body.Length) byte, diawali '$($body.Substring(0, [Math]::Min(40, $body.Length)))')."
    }
    try {
        return ($body | ConvertFrom-Json)
    } catch {
        throw "JSON $path tidak bisa diparse: $($_.Exception.Message)"
    }
}

# Cheap reachability probe used by the URL manager. Returns a status object
# instead of throwing, so a dead candidate does not abort the sweep.
function Test-BridgeUrl([string]$url, [string]$bridgeKey, [int]$timeoutSec = 8) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri "$($url.TrimEnd('/'))/api/bridge/keys" -Headers (Get-BridgeHeaders $bridgeKey) -UseBasicParsing -TimeoutSec $timeoutSec
        $sw.Stop()
        $ok = $false; $note = ""
        $body = [string]$r.Content
        if ($body -match 'ERR_NGROK') { $note = "ngrok interstitial" }
        elseif ($body.TrimStart() -notmatch '^\{') { $note = "bukan JSON ($($body.Length)B)" }
        else { $ok = $true; $note = "auth ok" }
        return [pscustomobject]@{ Url = $url; Ok = $ok; Code = [int]$r.StatusCode; Ms = $sw.ElapsedMilliseconds; Note = $note }
    } catch {
        $sw.Stop()
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $note = if ($code) { "HTTP $code" } else { $_.Exception.Message.Split([Environment]::NewLine)[0] }
        return [pscustomobject]@{ Url = $url; Ok = $false; Code = $code; Ms = $sw.ElapsedMilliseconds; Note = $note }
    }
}

function Get-ModelCatalog {
    $headers = @{
        "Authorization"              = "Bearer $script:ApiKey"
        "ngrok-skip-browser-warning" = "true"
    }
    $resp = Invoke-WebRequest -Uri "$script:ApiBase/models" -Headers $headers -UseBasicParsing -TimeoutSec 30
    return ($resp.Content | ConvertFrom-Json).data
}

# Points BaseUrl/ApiBase/ApiKey at a working endpoint without running a sync, for
# the screens that only need to talk to 9Router.
function Connect-Bridge($Config) {
    $script:BaseUrl = "$($Config.remoteUrl)".TrimEnd("/")
    $script:ApiBase = "$script:BaseUrl/v1"
    $script:ApiKey = ""
    $keys = Get-BridgeJson "keys" "$($Config.bridgeKey)"
    foreach ($k in @($keys.keys)) {
        if ($k.isActive -and $k.key) { $script:ApiKey = $k.key; break }
    }
    if (-not $script:ApiKey) { throw "Tidak ada API key aktif di /keys." }
}

# One cheap chat completion. Used by the TUI's per-model health check, which is
# how a provider that has run out of credit shows up before it is picked up in
# a real conversation.
function Test-ModelLive([string]$modelId, [int]$timeoutSec = 25) {
    $headers = @{
        "Authorization"              = "Bearer $script:ApiKey"
        "ngrok-skip-browser-warning" = "true"
    }
    $body = @{
        model = $modelId
        messages = @(@{ role = "user"; content = "reply with the single word: ok" })
        max_tokens = 8
        stream = $false
    } | ConvertTo-Json -Depth 6

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$script:ApiBase/chat/completions" -Headers $headers -Method Post -Body $body -ContentType "application/json" -TimeoutSec $timeoutSec
        $sw.Stop()
        if ($r.error) {
            return [pscustomobject]@{ Model = $modelId; Ok = $false; Code = 0; Ms = $sw.ElapsedMilliseconds; Note = "$($r.error.message)" }
        }
        return [pscustomobject]@{ Model = $modelId; Ok = $true; Code = 200; Ms = $sw.ElapsedMilliseconds; Note = "ok" }
    } catch {
        $sw.Stop()
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $note = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $d = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($d.error -and $d.error.message) { $note = $d.error.message }
            } catch { $note = $null }
        }
        if (-not $note) { $note = if ($code) { "HTTP $code" } else { $_.Exception.Message.Split([Environment]::NewLine)[0] } }
        return [pscustomobject]@{ Model = $modelId; Ok = $false; Code = $code; Ms = $sw.ElapsedMilliseconds; Note = $note }
    }
}

# ---------------------------------------------------------------------------
# File IO
# ---------------------------------------------------------------------------

# Returns "written", "unchanged" or "whatif". Rewriting identical content would
# churn mtimes and fill the backup ring with duplicates on every run.
function Save-FileUtf8([string]$path, [string]$content) {
    if (-not $script:Cmd.ShouldProcess($path, "write")) { return "whatif" }

    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $path) {
        $current = [System.IO.File]::ReadAllText($path)
        if ($current -ceq $content) { return "unchanged" }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        Copy-Item -LiteralPath $path -Destination "$path.$stamp.bak" -Force
        $leaf = Split-Path -Leaf $path
        Get-ChildItem -LiteralPath $parent -Filter "$leaf.*.bak" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip $script:BackupKeep |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    # UTF8Encoding($false): plain [Text.Encoding]::UTF8 emits a BOM, which some
    # TOML and JSON readers choke on.
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
    return "written"
}

# Shared reporting for a single write result.
function Report-Write([string]$tool, [string]$path, [string]$result, [string]$detail) {
    $leaf = Split-Path -Leaf $path
    switch ($result) {
        "written"   { Write-Success ("{0,-10} -> {1}" -f $tool, $leaf); Add-Report $tool $path "updated" $detail }
        "unchanged" { Write-Info    ("{0,-10} -> {1} (sudah sesuai)" -f $tool, $leaf); Add-Report $tool $path "unchanged" $detail }
        default     { Write-Info    ("{0,-10} -> {1} (WhatIf, tidak ditulis)" -f $tool, $leaf, $result); Add-Report $tool $path "whatif" $detail }
    }
}

# Windows PowerShell's Get-Content decodes with the console ANSI codepage, not
# UTF-8. A file containing an em-dash comes back as three unrelated characters,
# and writing it out re-encodes the damage - one extra layer of mojibake per
# sync. Every read here therefore goes through an explicit UTF-8 decoder.
function Read-TextUtf8([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Read-JsonOrNull([string]$path) {
    $raw = Read-TextUtf8 $path
    if ($null -eq $raw -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# Returns lines with endings normalised to LF, so a CRLF file does not get
# rewritten (and backed up) on every single run.
function Read-LinesOrEmpty([string]$path) {
    $raw = Read-TextUtf8 $path
    if ($null -eq $raw -or $raw -eq "") { return [string[]]@() }
    $t = $raw -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    return [string[]]($t -split "`n")
}

# ---------------------------------------------------------------------------
# JSON writer (2-space indent, stable key order)
# ---------------------------------------------------------------------------

function ConvertTo-JsonString([string]$s) {
    return (ConvertTo-Json -InputObject $s -Compress)
}

function ConvertTo-JsonText($value, [int]$indent = 0) {
    $pad = " " * $indent
    $padInner = " " * ($indent + 2)

    if ($null -eq $value) { return "null" }
    if ($value -is [bool])   { if ($value) { return "true" } else { return "false" } }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
        return [string]$value
    }
    if ($value -is [string]) { return (ConvertTo-JsonString $value) }

    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Count -eq 0) { return "{}" }
        $parts = @()
        foreach ($k in $value.Keys) {
            $parts += "$padInner$(ConvertTo-JsonString ([string]$k)): $(ConvertTo-JsonText $value[$k] ($indent + 2))"
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }

    if ($value -is [System.Collections.IEnumerable]) {
        $arr = @($value)
        if ($arr.Count -eq 0) { return "[]" }
        $parts = @()
        foreach ($item in $arr) { $parts += "$padInner$(ConvertTo-JsonText $item ($indent + 2))" }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }

    $props = @($value.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" })
    if ($props.Count -eq 0) { return "{}" }
    $parts = @()
    foreach ($p in $props) {
        $parts += "$padInner$(ConvertTo-JsonString $p.Name): $(ConvertTo-JsonText $p.Value ($indent + 2))"
    }
    return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

function Remove-JsonProp($obj, [string]$name) {
    if ($null -eq $obj) { return $obj }
    if ($obj -is [System.Collections.IDictionary]) { $obj.Remove($name); return $obj }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { $obj.PSObject.Properties.Remove($name) }
    return $obj
}

# ---------------------------------------------------------------------------
# Model pins
#
# Two shapes appear in the wild:
#   "9router/some-model"                        (opencode, omp roles)
#   { "providerID": "9router", "model": "..." }  (opencode agents)
# Anything else - a built-in provider such as opencode/big-pickle, a bare model
# name, an empty value - is somebody's own choice and is never touched.
# ---------------------------------------------------------------------------

function Get-ModelPin($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [string]) {
        $s = $value.Trim()
        if ($s -match '^9router/(.+)$') { return [pscustomobject]@{ Provider = "9router"; Model = $Matches[1] } }
        return $null
    }
    $names = $value.PSObject.Properties.Name
    if (($names -contains "providerID") -and ($names -contains "model")) {
        return [pscustomobject]@{ Provider = "$($value.providerID)"; Model = "$($value.model)" }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Minimal YAML block surgery (no YAML parser available in Windows PowerShell)
# ---------------------------------------------------------------------------

function Get-Indent([string]$line) {
    return $line.Length - $line.TrimStart(" ").Length
}

# Returns @{Start=<index>;End=<exclusive>} for the block introduced by $Key at
# $indent, or $null when the key is absent.
function Find-YamlBlock([string[]]$lines, [string]$key, [int]$indent) {
    $pat = "^" + (" " * $indent) + [regex]::Escape($key) + "\s*:"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pat) {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $t = $lines[$j].Trim()
                if ($t -eq "" -or $t.StartsWith("#")) { continue }
                if ((Get-Indent $lines[$j]) -le $indent) { return @{ Start = $i; End = $j } }
            }
            return @{ Start = $i; End = $lines.Count }
        }
    }
    return $null
}

# Returns a new line array. Editing a [string[]] parameter in place is not
# reliable: PowerShell binds a copy, so the caller's array stays untouched and
# the edit is silently lost. Always reassign the result.
function Set-YamlValue([string[]]$lines, [int]$start, [int]$end, [int]$indent, [string]$key, [string]$value) {
    $pat = "^" + (" " * $indent) + [regex]::Escape($key) + "\s*:"
    $out = [string[]]$lines.Clone()
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($out[$i] -match $pat) {
            $out[$i] = (" " * $indent) + $key + ": " + $value
            return $out
        }
    }
    return $out
}

function Remove-YamlKey([string[]]$lines, [int]$start, [int]$end, [int]$indent, [string]$key) {
    $pat = "^" + (" " * $indent) + [regex]::Escape($key) + "\s*:"
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -gt $start -and $i -lt $end -and $lines[$i] -match $pat) { continue }
        [void]$out.Add($lines[$i])
    }
    return [string[]]$out.ToArray()
}

function Replace-YamlBlock([string[]]$lines, [int]$start, [int]$end, [string[]]$replacement) {
    $head = if ($start -gt 0) { $lines[0..($start - 1)] } else { @() }
    $tail = if ($end -lt $lines.Count) { $lines[$end..($lines.Count - 1)] } else { @() }
    return [string[]]@($head + $replacement + $tail)
}

function Set-TomlValue([string[]]$lines, [string]$key, [string]$value) {
    $pat = "^\s*" + [regex]::Escape($key) + "\s*="
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pat) {
            $lines[$i] = "$key = `"$value`""
            return $lines
        }
    }
    $out = @($lines) + @("$key = `"$value`"")
    return [string[]]$out
}

# ---------------------------------------------------------------------------
# Current-state readers, so the summary can report what actually moved
# ---------------------------------------------------------------------------

function Get-OpenCodeModelIds($cfg) {
    if (-not $cfg) { return [string[]]@() }
    $p = $null
    if ($cfg.PSObject.Properties.Name -contains "providers" -and $cfg.providers) { $p = $cfg.providers }
    elseif ($cfg.PSObject.Properties.Name -contains "provider" -and $cfg.provider) { $p = $cfg.provider }
    if (-not $p -or $p.PSObject.Properties.Name -notcontains "9router") { return [string[]]@() }
    $nine = $p.'9router'
    if (-not $nine -or $nine.PSObject.Properties.Name -notcontains "models" -or -not $nine.models) { return [string[]]@() }
    return [string[]]$nine.models.PSObject.Properties.Name
}

function Get-OmpModelIds([string[]]$lines) {
    $mb = Find-YamlBlock $lines "models" 4
    if (-not $mb) { return [string[]]@() }
    $out = @()
    for ($i = $mb.Start + 1; $i -lt $mb.End; $i++) {
        if ($lines[$i] -match '^\s*- id:\s*(.+?)\s*$') { $out += $Matches[1] }
    }
    return $out
}

function Get-HermesModelIds([string[]]$lines) {
    $mb = Find-YamlBlock $lines "models" 4
    if (-not $mb) { return [string[]]@() }
    $out = @()
    for ($i = $mb.Start + 1; $i -lt $mb.End; $i++) {
        $t = $lines[$i].Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ($t -match '^([^:]+):') { $out += $Matches[1].Trim([char[]]@("'", '"')) }
    }
    return $out
}

# fallback_providers entries reach 9Router through base_url and bypass the tool's
# model list, so any of them can still work even when the model is not in the
# synced set. They are reported, never rewritten.
function Get-HermesFallbackRefs([string[]]$lines, [string]$hostPattern) {
    $fb = Find-YamlBlock $lines "fallback_providers" 0
    if (-not $fb) { return @() }
    $out = @(); $cur = $null
    for ($i = $fb.Start + 1; $i -lt $fb.End; $i++) {
        $l = $lines[$i]
        $t = $l.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ((Get-Indent $l) -le 2) {
            if ($cur -and $cur.BaseUrl -like "*$hostPattern*") { $out += $cur }
            $cur = [pscustomobject]@{ Model = ""; BaseUrl = ""; Provider = "" }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*model:\s*(.+?)\s*$')        { $cur.Model    = $Matches[1].Trim([char[]]@("'", '"')) }
        elseif ($l -match '^\s*base_url:\s*(.+?)\s*$') { $cur.BaseUrl  = $Matches[1].Trim([char[]]@("'", '"')) }
        elseif ($l -match '^\s*provider:\s*(.+?)\s*$') { $cur.Provider = $Matches[1].Trim([char[]]@("'", '"')) }
    }
    if ($cur -and $cur.BaseUrl -like "*$hostPattern*") { $out += $cur }
    return $out
}

# ---------------------------------------------------------------------------
# Model resolution
# ---------------------------------------------------------------------------

# Every tool in the payload is scanned, not just the two that happen to be
# populated today. A model configured through omp or crush on Android should
# reach the PC without this script needing to be taught about it first.
function Resolve-Models($statuses, $catalog) {
    $wanted = New-Object System.Collections.ArrayList
    $source = @{}
    $seen = @{}

    $add = {
        param($rawId, $toolName)
        if (-not $rawId) { return }
        $id = "$rawId".Trim()
        if (-not $id -or $seen.ContainsKey($id)) { return }
        $seen[$id] = $true
        $source[$id] = $toolName
        [void]$wanted.Add($id)
    }

    $collect = {
        param($cfg, $toolName)
        if (-not $cfg) { return }
        $p = $null
        if ($cfg.PSObject.Properties.Name -contains "providers" -and $cfg.providers) { $p = $cfg.providers }
        elseif ($cfg.PSObject.Properties.Name -contains "provider" -and $cfg.provider) { $p = $cfg.provider }
        if (-not $p) { return }
        if ($p.PSObject.Properties.Name -notcontains "9router") { return }
        $nine = $p.'9router'
        if (-not $nine -or $nine.PSObject.Properties.Name -notcontains "models") { return }

        $models = $nine.models
        if (-not $models) { return }
        if ($models -is [string]) { & $add $models $toolName; return }
        $isList = $models -is [System.Collections.IEnumerable] -and
                  $models -isnot [System.Management.Automation.PSCustomObject]
        if ($isList) {
            foreach ($m in $models) {
                if ($m -is [string]) { & $add $m $toolName }
                elseif ($m.PSObject.Properties.Name -contains "id") { & $add $m.id $toolName }
            }
        } else {
            foreach ($prop in $models.PSObject.Properties) { & $add $prop.Name $toolName }
        }
    }

    # Payload order is preserved by ConvertFrom-Json, so the resulting list is
    # stable across runs even though the source set changes.
    $used = New-Object System.Collections.ArrayList
    foreach ($prop in $statuses.PSObject.Properties) {
        $entry = $prop.Value
        if (-not $entry) { continue }
        $names = $entry.PSObject.Properties.Name
        if ($names -contains "config" -and $entry.config) {
            & $collect $entry.config $prop.Name
            [void]$used.Add($prop.Name)
        } elseif ($names -contains "settings" -and $entry.settings) {
            & $collect $entry.settings $prop.Name
            [void]$used.Add($prop.Name)
        }
    }
    if ($script:Quiet) {
        $script:ModelSources = $source
    } else {
        Write-Detail "sumber model: $($used -join ', ')"
        $script:ModelSources = $source
    }

    $catalogById = @{}
    foreach ($m in $catalog) { $catalogById[$m.id] = $m }

    $resolved = New-Object System.Collections.ArrayList
    foreach ($id in $wanted) {
        $lookup = $id
        if (-not $catalogById.ContainsKey($lookup) -and $script:ModelAlias.ContainsKey($lookup)) {
            $lookup = $script:ModelAlias[$lookup]
            Write-Info "Model '$id' tidak ada di katalog, dipetakan ke '$lookup'."
        }
        if (-not $catalogById.ContainsKey($lookup)) {
            Write-Warn "Model '$id' dilewati: tidak ada di katalog 9Router dan tidak ada alias."
            continue
        }
        $c = $catalogById[$lookup].capabilities
        $ctx = 128000; $maxOut = 16384; $vision = $false; $reasoning = $false; $tools = $true
        if ($c) {
            if ($c.contextWindow) { $ctx = [int]$c.contextWindow }
            if ($c.maxOutput) { $maxOut = [int]$c.maxOutput }
            $vision = [bool]$c.vision
            $reasoning = [bool]$c.reasoning
            $tools = [bool]$c.tools
        }
        [void]$resolved.Add([pscustomobject]@{
            id = $lookup; ctx = $ctx; maxOut = $maxOut
            vision = $vision; reasoning = $reasoning; tools = $tools
            source = $(if ($source.ContainsKey($id)) { $source[$id] } else { "" })
        })
    }
    return $resolved
}

# ---------------------------------------------------------------------------
# OpenCode  (~/.config/opencode/opencode.json)
#
# 9Router emits the v1 provider shape; OpenCode v2 expects plural `providers` with
# `package` / `settings`. The config is merged, not replaced, so mcp, agents and
# any other provider survive.
# ---------------------------------------------------------------------------

function Write-OpenCodeConfig([string]$defaultId) {
    $path = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    $cfg = Read-JsonOrNull $path
    $before = Get-OpenCodeModelIds $cfg
    $validIds = @($script:Models | ForEach-Object { $_.id })

    $existingProviders = $null
    if ($cfg) {
        if ($cfg.PSObject.Properties.Name -contains "providers" -and $cfg.providers) { $existingProviders = $cfg.providers }
        elseif ($cfg.PSObject.Properties.Name -contains "provider" -and $cfg.provider) { $existingProviders = $cfg.provider }
    }

    $pkg = "aisdk:@ai-sdk/openai-compatible"
    if ($existingProviders -and $existingProviders.PSObject.Properties.Name -contains "9router") {
        $nine = $existingProviders.'9router'
        foreach ($k in @("package", "npm")) {
            if ($nine.PSObject.Properties.Name -contains $k -and $nine.$k) { $pkg = $nine.$k; break }
        }
    }

    $providers = [ordered]@{}
    if ($existingProviders) {
        foreach ($p in $existingProviders.PSObject.Properties) {
            if ($p.Name -ne "9router") { $providers[$p.Name] = $p.Value }
        }
    }

    $modelObj = [ordered]@{}
    foreach ($m in $script:Models) {
        $caps = [ordered]@{ tools = [bool]$m.tools; input = [object[]]@("text"); output = [object[]]@("text") }
        if ($m.vision) { $caps["input"] = [object[]]@("text", "image") }
        $modelObj[$m.id] = [ordered]@{ name = $m.id; capabilities = $caps }
    }
    $providers["9router"] = [ordered]@{
        package  = $pkg
        settings = [ordered]@{ baseURL = $script:ApiBase; apiKey = $script:ApiKey }
        models   = $modelObj
    }

    # Unpin agents whose model is gone. The agent entry itself is kept so its
    # description, mode and tools survive; without a pin OpenCode falls back to
    # the top-level default.
    $agentsOut = $null
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains "agents") -and $cfg.agents) {
        $agentsOut = [ordered]@{}
        foreach ($ap in $cfg.agents.PSObject.Properties) {
            $entry = $ap.Value
            $pin = $null
            if ($entry -and ($entry.PSObject.Properties.Name -contains "model")) { $pin = Get-ModelPin $entry.model }
            if ($pin -and $pin.Provider -eq "9router" -and $validIds -notcontains $pin.Model) {
                $newEntry = [ordered]@{}
                foreach ($ep in $entry.PSObject.Properties) {
                    if ($ep.Name -ne "model") { $newEntry[$ep.Name] = $ep.Value }
                }
                $agentsOut[$ap.Name] = $newEntry
                $script:Dangling += [pscustomobject]@{
                    Tool = "opencode"; Where = "agents.$($ap.Name).model"; Model = $pin.Model
                }
                Write-Warn "opencode  -> agents.$($ap.Name) pin ke '$($pin.Model)' dilepas, model tidak ada lagi."
            } else {
                $agentsOut[$ap.Name] = $entry
            }
        }
    }

    $out = [ordered]@{}
    $seenProviderKey = $false
    if ($cfg) {
        foreach ($p in $cfg.PSObject.Properties) {
            if ($p.Name -eq "model") { $out["model"] = "9router/$defaultId" }
            elseif ($p.Name -eq "provider" -or $p.Name -eq "providers") { $out["providers"] = $providers; $seenProviderKey = $true }
            elseif ($p.Name -eq "agents" -and $agentsOut) { $out["agents"] = $agentsOut }
            else { $out[$p.Name] = $p.Value }
        }
    }
    if (-not $out.Contains("model")) { $out["model"] = "9router/$defaultId" }
    if (-not $seenProviderKey) { $out["providers"] = $providers }
    if (-not $out.Contains('$schema')) { $out['$schema'] = "https://opencode.ai/config.json" }

    $text = (ConvertTo-JsonText $out) + "`n"
    Add-Change "opencode" $path $before $validIds
    Report-Write "opencode" $path (Save-FileUtf8 $path $text) "$($script:Models.Count) model, default 9router/$defaultId"
}

# ---------------------------------------------------------------------------
# Oh My Pi  (~/.omp/agent/models.yml + config.yml)
# ---------------------------------------------------------------------------

function Write-OmpConfig([string]$defaultId) {
    $modelsPath = Join-Path $env:USERPROFILE ".omp\agent\models.yml"
    $cfgPath = Join-Path $env:USERPROFILE ".omp\agent\config.yml"
    $validIds = @($script:Models | ForEach-Object { $_.id })

    if (-not (Test-Path -LiteralPath $modelsPath)) {
        Write-Warn "Oh My Pi  -> omp tidak terinstall di PC ini, dilewati."
        Write-Warn "            models.yml tidak ada di $modelsPath"
        Write-Warn "            install omp dulu, atau hapus 'omp' dari tools di config."
        Add-Report "omp" $modelsPath "not-installed" "omp tidak terinstall di PC ini (models.yml tidak ada)"
        return
    }

    $lines = Read-LinesOrEmpty $modelsPath
    if ($lines.Count -eq 0) { Write-Err "Oh My Pi  -> models.yml kosong."; Add-Report "omp" $modelsPath "failed" "models.yml kosong"; return }

    $before = Get-OmpModelIds $lines

    # Connection fields live at indent 4 under providers.<name>; authHeader,
    # disableStrictTools, headers and discovery are left untouched.
    $provBlock = Find-YamlBlock $lines "9router" 2
    if (-not $provBlock) {
        Write-Warn "Oh My Pi  -> blok '9router' tidak ada di models.yml, dilewati."
        Add-Report "omp" $modelsPath "skipped" "blok 9router tidak ada"
        return
    }
    $lines = Set-YamlValue $lines $provBlock.Start $provBlock.End 4 "baseUrl" $script:ApiBase
    $lines = Set-YamlValue $lines $provBlock.Start $provBlock.End 4 "apiKey" $script:ApiKey

    $mb = Find-YamlBlock $lines "models" 4
    $gen = [string[]]@("    models:")
    foreach ($m in $script:Models) {
        $gen += "      - id: $($m.id)"
        $gen += "        name: $($m.id)"
        $gen += "        contextWindow: $($m.ctx)"
        $gen += "        maxTokens: $($m.maxOut)"
        $gen += "        reasoning: $($m.reasoning.ToString().ToLower())"
        $gen += "        input:"
        $gen += "          - text"
        if ($m.vision) { $gen += "          - image" }
        $gen += "        supportsTools: $($m.tools.ToString().ToLower())"
    }
    if ($mb) { $lines = Replace-YamlBlock $lines $mb.Start $mb.End $gen }
    else { $lines = @($lines) + $gen }

    Add-Change "omp" $modelsPath $before $validIds
    Report-Write "omp" $modelsPath (Save-FileUtf8 $modelsPath ((@($lines) -join "`n") + "`n")) "$($script:Models.Count) model di models.yml"

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        # models.yml exists but config.yml does not, so omp is present but
        # unusual. Report it as missing rather than pretending the tool is
        # absent, because the two need different fixes.
        Add-Report "omp" $cfgPath "skipped" "config.yml tidak ada (models.yml ada, berarti omp terinstall tapi tidak lengkap)"
        return
    }
    $clines = Read-LinesOrEmpty $cfgPath
    $rb = Find-YamlBlock $clines "modelRoles" 0
    if (-not $rb) {
        Write-Warn "Oh My Pi  -> modelRoles tidak ditemukan, default tidak diubah."
        Add-Report "omp" $cfgPath "skipped" "modelRoles tidak ada"
        return
    }

    $hasDefault = $false
    for ($k = $rb.Start + 1; $k -lt $rb.End; $k++) {
        if ($clines[$k] -match '^\s+default\s*:') { $hasDefault = $true; break }
    }
    if ($hasDefault) {
        $clines = Set-YamlValue $clines $rb.Start $rb.End 2 "default" "9router/$defaultId"
    } else {
        $clines = @($clines[0..($rb.Start)]) + @("  default: 9router/$defaultId") + @($clines[($rb.Start + 1)..($clines.Count - 1)])
        Write-Warn "Oh My Pi  -> modelRoles.default tidak ada, ditambahkan."
    }

    # Any other role (advisor, smol, ...) pinned to a 9router model that no longer
    # exists is dropped. `default` is exempt because it was just rewritten.
    $drop = @()
    for ($k = $rb.Start + 1; $k -lt $rb.End; $k++) {
        if ($clines[$k] -match '^\s+(\w[\w-]*)\s*:\s*(\S.*?)\s*$') {
            $role = $Matches[1]; $val = $Matches[2]
            if ($role -eq "default") { continue }
            $pin = Get-ModelPin $val
            if ($pin -and $pin.Provider -eq "9router" -and $validIds -notcontains $pin.Model) {
                $drop += $role
                $script:Dangling += [pscustomobject]@{
                    Tool = "omp"; Where = "modelRoles.$role"; Model = $pin.Model
                }
            }
        }
    }
    foreach ($role in $drop) {
        $b = Find-YamlBlock $clines "modelRoles" 0
        $clines = Remove-YamlKey $clines $b.Start $b.End 2 $role
        Write-Warn "Oh My Pi  -> modelRoles.$role pin ke model yang hilang, dilepas."
    }

    Report-Write "omp" $cfgPath (Save-FileUtf8 $cfgPath ((@($clines) -join "`n") + "`n")) "modelRoles.default = 9router/$defaultId"
}

# ---------------------------------------------------------------------------
# Hermes  (%LOCALAPPDATA%\hermes\config.yaml + .env)
#
# `hermes config path` points at LOCALAPPDATA, not ~/.hermes. The file holds ~30
# top level sections and other providers, so only the 9router block is touched.
# ---------------------------------------------------------------------------

function Write-HermesConfig([string]$defaultId) {
    $base = Join-Path $env:LOCALAPPDATA "hermes"
    $cfgPath = Join-Path $base "config.yaml"
    $envPath = Join-Path $base ".env"
    $validIds = @($script:Models | ForEach-Object { $_.id })

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Warn "Hermes    -> hermes tidak terinstall di PC ini, dilewati."
        Write-Warn "            config.yaml tidak ada di $cfgPath"
        Write-Warn "            install Hermes dulu, atau hapus 'hermes' dari tools di config."
        Add-Report "hermes" $cfgPath "not-installed" "hermes tidak terinstall di PC ini (config.yaml tidak ada)"
        return
    }

    $lines = Read-LinesOrEmpty $cfgPath
    $before = Get-HermesModelIds $lines

    # fallback_providers call 9Router through base_url and can name a model that
    # is not in the synced set. Such a model still resolves at the bridge, so
    # these entries are listed for awareness and left exactly as they are.
    $apiHost = ([Uri]$script:ApiBase).Host
    foreach ($f in (Get-HermesFallbackRefs $lines $apiHost)) {
        $script:OutOfSync += [pscustomobject]@{ Tool = "hermes"; Model = $f.Model; BaseUrl = $f.BaseUrl }
    }

    $provName = "9router-cloud"
    $pb = Find-YamlBlock $lines "providers" 0
    if ($pb) {
        foreach ($cand in @("9router-cloud", "9router")) {
            if (Find-YamlBlock $lines $cand 2) { $provName = $cand; break }
        }
    }

    $mb = Find-YamlBlock $lines "model" 0
    if ($mb) {
        $lines = Set-YamlValue $lines $mb.Start $mb.End 2 "default" "`"$defaultId`""
        $lines = Set-YamlValue $lines $mb.Start $mb.End 2 "provider" "`"$provName`""
        $lines = Set-YamlValue $lines $mb.Start $mb.End 2 "base_url" "`"$script:ApiBase`""
        $lines = Set-YamlValue $lines $mb.Start $mb.End 2 "api_key" '${OPENAI_API_KEY}'
    }

    $nb = Find-YamlBlock $lines $provName 2
    if ($nb) {
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "name" $provName
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "base_url" "`"$script:ApiBase`""
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "key_env" "OPENAI_API_KEY"
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "model" "`"$defaultId`""
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "default_model" "`"$defaultId`""
        $lines = Set-YamlValue $lines $nb.Start $nb.End 4 "discover_models" "false"

        # providers.<name> sits at indent 2, so its keys are indent 4 and the
        # model map entries indent 6.
        $mm = Find-YamlBlock $lines "models" 4
        $gen = [string[]]@("    models:")
        foreach ($m in $script:Models) { $gen += "      $($m.id): {}" }
        if ($mm) { $lines = Replace-YamlBlock $lines $mm.Start $mm.End $gen }
        else { $lines = @($lines[0..($nb.End - 1)]) + $gen + @($lines[$nb.End..($lines.Count - 1)]) }
    } else {
        Write-Warn "Hermes    -> providers.$provName tidak ada, config tidak diubah."
        Add-Report "hermes" $cfgPath "skipped" "providers.$provName tidak ditemukan"
        return
    }

    Add-Change "hermes" $cfgPath $before $validIds
    Report-Write "hermes" $cfgPath (Save-FileUtf8 $cfgPath ((@($lines) -join "`n") + "`n")) "$($script:Models.Count) model, default $defaultId"

    $elines = Read-LinesOrEmpty $envPath
    $found = $false
    for ($i = 0; $i -lt $elines.Count; $i++) {
        if ($elines[$i] -match '^\s*OPENAI_API_KEY\s*=') { $elines[$i] = "OPENAI_API_KEY=$script:ApiKey"; $found = $true; break }
    }
    if (-not $found) { $elines = @($elines) + @("OPENAI_API_KEY=$script:ApiKey") }
    Report-Write "hermes" $envPath (Save-FileUtf8 $envPath ((@($elines) -join "`n") + "`n")) "OPENAI_API_KEY"
}

# ---------------------------------------------------------------------------
# Claude Code / Codex (merge only, own settings preserved)
# ---------------------------------------------------------------------------

function Write-ClaudeConfig {
    $path = Join-Path $env:USERPROFILE ".claude\settings.json"
    # These two are merge-only. Creating the file for a PC that has never run
    # Claude Code would leave a settings.json that no tool reads, so an absent
    # file is reported instead. Running the tool once is what creates it.
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "Claude    -> .claude\settings.json tidak ada, dilewati."
        Write-Warn "            jalankan claude sekali supaya config-nya dibuat, lalu sync lagi."
        Add-Report "claude" $path "not-installed" "claude belum pernah dijalankan di PC ini (settings.json tidak ada)"
        return
    }
    $cfg = Read-JsonOrNull $path

    $out = [ordered]@{}
    if ($cfg) {
        foreach ($p in $cfg.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    $out["hasCompletedOnboarding"] = $true

    if (-not $out.Contains("env") -or $null -eq $out["env"]) { $out["env"] = [pscustomobject]@{} }
    $envObj = $out["env"]
    if ($envObj -is [System.Collections.IDictionary]) {
        $envObj["ANTHROPIC_BASE_URL"] = $script:ApiBase
        $envObj["ANTHROPIC_AUTH_TOKEN"] = $script:ApiKey
    } else {
        $envObj | Add-Member -MemberType NoteProperty -Name "ANTHROPIC_BASE_URL" -Value $script:ApiBase -Force
        $envObj | Add-Member -MemberType NoteProperty -Name "ANTHROPIC_AUTH_TOKEN" -Value $script:ApiKey -Force
    }

    Report-Write "claude" $path (Save-FileUtf8 $path ((ConvertTo-JsonText $out) + "`n")) "ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN"
}

function Write-CodexConfig([string]$defaultId) {
    $path = Join-Path $env:USERPROFILE ".codex\config.toml"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "Codex     -> .codex\config.toml tidak ada, dilewati."
        Write-Warn "            jalankan codex sekali supaya config-nya dibuat, lalu sync lagi."
        Add-Report "codex" $path "not-installed" "codex belum pernah dijalankan di PC ini (config.toml tidak ada)"
        return
    }
    $lines = Read-LinesOrEmpty $path
    $lines = Set-TomlValue $lines "base_url" $script:ApiBase
    $lines = Set-TomlValue $lines "api_key" $script:ApiKey
    $lines = Set-TomlValue $lines "model" "9router/$defaultId"
    Report-Write "codex" $path (Save-FileUtf8 $path ((@($lines) -join "`n") + "`n")) "base_url, api_key, model"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Sync9Router {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [string[]]$Tools = @(),
        [string]$DefaultModel = "",
        [ValidateRange(1, 50)][int]$BackupKeep = 0,
        [switch]$Quiet
    )

    $script:Cmd = $PSCmdlet
    $script:Quiet = [bool]$Quiet
    $script:Report = @()
    $script:Changes = @()
    $script:Dangling = @()
    $script:OutOfSync = @()
    $script:ApiKey = ""
    $script:Models = @()

    # -File hands "a,b" over as a single string, so split on commas here as well
    # and the two call paths behave the same. A name that does not exist is
    # reported rather than quietly dropped, because a typo would otherwise sync
    # a subset of tools and look like it worked.
    $requested = @()
    foreach ($t in @($Tools)) { $requested += @("$t" -split ",") }
    if ($requested.Count -eq 0) { $requested = @($Config.tools | ForEach-Object { "$_" }) }
    $requested = @($requested | Where-Object { $_ })

    $unknown = @($requested | Where-Object { $script:AllTools -notcontains "$_" })
    if ($unknown.Count -gt 0) {
        Write-Warn "Tool tidak dikenal, dilewati: $($unknown -join ', ')"
    }
    $Tools = @($requested | Where-Object { $script:AllTools -contains "$_" })
    if ($Tools.Count -eq 0) { $Tools = @($script:AllTools) }

    $script:BackupKeep = if ($BackupKeep -gt 0) { $BackupKeep } else { [int]$Config.backupKeep }
    if ($script:BackupKeep -lt 1) { $script:BackupKeep = 5 }

    $script:BaseUrl = "$($Config.remoteUrl)".TrimEnd("/")
    $script:ApiBase = "$script:BaseUrl/v1"
    $bridgeKey = "$($Config.bridgeKey)".Trim()

    $result = [ordered]@{
        Ok = $false; Error = ""; Endpoint = $script:ApiBase
        DefaultModel = ""; Models = @(); ModelIds = @()
        Rows = @(); Changes = @(); Dangling = @(); OutOfSync = @()
        WhatIf = [bool]$WhatIfPreference
    }

    try {
        Write-Info "Connecting to $script:BaseUrl"
        $statuses = Get-BridgeJson "cli-tools/all-statuses" $bridgeKey
        Write-Success "Bridge terhubung, auth ok."

        try {
            $keys = Get-BridgeJson "keys" $bridgeKey
            foreach ($k in @($keys.keys)) {
                if ($k.isActive -and $k.key) { $script:ApiKey = $k.key; break }
            }
        } catch { Write-Warn "Gagal ambil /keys: $($_.Exception.Message)" }

        if (-not $script:ApiKey) {
            foreach ($prop in $statuses.PSObject.Properties) {
                $entry = $prop.Value
                if (-not $entry) { continue }
                foreach ($key in @("config", "settings")) {
                    if ($entry.PSObject.Properties.Name -notcontains $key -or -not $entry.$key) { continue }
                    $c = $entry.$key
                    $holder = $null
                    if ($c.PSObject.Properties.Name -contains "providers" -and $c.providers) { $holder = $c.providers }
                    elseif ($c.PSObject.Properties.Name -contains "provider" -and $c.provider) { $holder = $c.provider }
                    if (-not $holder -or $holder.PSObject.Properties.Name -notcontains "9router") { continue }
                    $nine = $holder.'9router'
                    foreach ($k2 in @("apiKey", "options", "settings")) {
                        if ($nine.PSObject.Properties.Name -contains $k2 -and $nine.$k2 -is [string] -and $nine.$k2) {
                            $script:ApiKey = $nine.$k2
                            break
                        }
                    }
                    if ($script:ApiKey) { break }
                }
                if ($script:ApiKey) { break }
            }
            if ($script:ApiKey) { Write-Warn "API key diambil dari config CLI tool, bukan /keys." }
        }
        if (-not $script:ApiKey) { throw "API key 9Router tidak ditemukan (/keys dan config CLI tool kosong)." }
        Write-Success "API key 9Router diperoleh."

        Write-Info "Mengambil katalog model dari $script:ApiBase/models ..."
        $catalog = Get-ModelCatalog
        Write-Success "Katalog: $(@($catalog).Count) model."

        $script:Models = Resolve-Models $statuses $catalog
        if ($script:Models.Count -eq 0) { throw "Tidak ada model yang bisa diresolve dari config CLI tool 9Router." }

        Write-Host ""
        Write-Info "Model hasil resolusi ($($script:Models.Count)):"
        foreach ($m in $script:Models) {
            Write-Detail ("{0,-42} ctx={1,-8} maxOut={2,-7} vision={3,-5} reasoning={4}" -f $m.id, $m.ctx, $m.maxOut, $m.vision, $m.reasoning)
        }

        $defaultId = $DefaultModel
        if (-not $defaultId) { $defaultId = "$($Config.defaultModel)".Trim() }
        if (-not $defaultId) {
            foreach ($prop in $statuses.PSObject.Properties) {
                $entry = $prop.Value
                if (-not $entry) { continue }
                foreach ($key in @("config", "settings")) {
                    if ($entry.PSObject.Properties.Name -notcontains $key -or -not $entry.$key) { continue }
                    if ($entry.$key.PSObject.Properties.Name -contains "model" -and $entry.$key.model) {
                        $defaultId = "$($entry.$key.model)"; break
                    }
                }
                if ($defaultId) { break }
            }
        }
        $defaultId = "$defaultId".Trim()
        if (-not $defaultId) {
            $defaultId = $script:Models[0].id
            Write-Warn "Default model tidak ditemukan di 9Router, memakai '$defaultId'."
        }
        # "9router/provider/model-name" -> "provider/model-name": drop only the
        # leading 9router segment, because the model id itself contains slashes.
        if ($defaultId -match '^9router/(.+)$') { $defaultId = $Matches[1] }

        $ids = @($script:Models | ForEach-Object { $_.id })
        if ($ids -notcontains $defaultId) {
            $fallback = $ids[0]
            Write-Warn "Default '$defaultId' tidak ada di daftar hasil resolusi, memakai '$fallback'."
            $defaultId = $fallback
        }
        Write-Host ""
        Write-Info "Default model: $defaultId"
        Write-Host ""

        if ($Tools -contains "opencode") { Write-OpenCodeConfig $defaultId }
        if ($Tools -contains "omp")      { Write-OmpConfig $defaultId }
        if ($Tools -contains "hermes")   { Write-HermesConfig $defaultId }
        if ($Tools -contains "claude")   { Write-ClaudeConfig }
        if ($Tools -contains "codex")    { Write-CodexConfig $defaultId }

        $result.Ok = $true
    } catch {
        $result.Ok = $false
        $result.Error = $_.Exception.Message
    }

    $result.DefaultModel = $defaultId
    $result.Models = $script:Models
    $result.ModelIds = @($script:Models | ForEach-Object { $_.id })
    $result.Rows = $script:Report
    $result.Changes = $script:Changes
    $result.Dangling = $script:Dangling
    $result.OutOfSync = $script:OutOfSync

    # A dry run tells you what would happen, which is not what happened.
    if ($result.Ok -and -not $WhatIfPreference) { Record-SyncRun $Config $result }

    $script:Result = $result
    return $result
}

function Show-SyncReport($result) {
    if ($result.Rows.Count -gt 0) {
        Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
        $color = @{ updated = "Green"; unchanged = "DarkGray"; skipped = "Yellow"; failed = "Red"; whatif = "DarkGray" }
        foreach ($r in $result.Rows) {
            $c = if ($color.ContainsKey($r.Status)) { $color[$r.Status] } else { "Gray" }
            Write-Host ("  {0,-9} {1,-10} {2}" -f $r.Tool, $r.Status, $r.Detail) -ForegroundColor $c
        }
        Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
    }

    $moved = @($result.Changes | Where-Object { $_.Added.Count -gt 0 -or $_.Removed.Count -gt 0 })
    if ($moved.Count -gt 0) {
        Write-Host "  Ringkasan perubahan model:" -ForegroundColor Cyan
        foreach ($c in $moved) {
            $parts = @()
            if ($c.Added.Count -gt 0)   { $parts += "+$($c.Added.Count) ($($c.Added -join ', '))" }
            if ($c.Removed.Count -gt 0) { $parts += "-$($c.Removed.Count) ($($c.Removed -join ', '))" }
            Write-Host ("    {0,-9} {1} -> {2}   {3}" -f $c.Tool, $c.Before, $c.After, ($parts -join "  ")) -ForegroundColor Green
        }
    }

    if ($result.Dangling.Count -gt 0) {
        Write-Host "  Pin dilepas (model sudah tidak ada di 9Router):" -ForegroundColor Yellow
        foreach ($d in $result.Dangling) {
            Write-Host ("    {0,-9} {1,-28} -> {2}" -f $d.Tool, $d.Where, $d.Model) -ForegroundColor Yellow
        }
    }

    if ($result.OutOfSync.Count -gt 0) {
        Write-Host "  Di luar daftar sync, tidak disentuh (base_url langsung):" -ForegroundColor DarkGray
        foreach ($o in $result.OutOfSync) {
            Write-Host ("    {0,-9} {1}" -f $o.Tool, $o.Model) -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------------------
# CLI entry point (skipped when dot-sourced)
# ---------------------------------------------------------------------------

if (-not $__dotSourced) {
    # The parameter list is bound positionally after the named ones, so a stray
    # argument lands in $RemoteUrl. That is how a typo used to point the whole
    # sync at a nonsense endpoint and fail with a confusing DNS error instead.
    # Anything that is not a URL is rejected here.
    if ($RemoteUrl -and $RemoteUrl -notmatch '^https?://') {
        Write-Host ""
        Write-Err "Endpoint '$RemoteUrl' bukan URL yang bisa dipakai."
        Write-Host "    Penyebab yang paling sering: argumen '-Tools a,b' dipecah cmd," -ForegroundColor DarkGray
        Write-Host "    lalu 'b' mengikat ke parameter berikutnya secara posisional." -ForegroundColor DarkGray
        Write-Host "    Dari cmd  : sync-9router.bat --cli -Tools a b" -ForegroundColor DarkGray
        Write-Host "    Dari PowerShell: .\sync-9router.ps1 -Tools a,b" -ForegroundColor DarkGray
        exit 2
    }

    # -File does not split on commas, so a value like "a,b" arrives as one
    # string. Accept both spellings rather than silently syncing a tool that
    # does not exist.
    $toolArg = @()
    foreach ($t in @($Tools)) { $toolArg += @("$t" -split ",") }
    $Tools = @($toolArg | Where-Object { $_ })

    $cfg = if ($NoConfig) { @{} } else { Get-Sync9RouterConfig }
    foreach ($k in $script:ConfigDefaults.Keys) { if (-not $cfg.ContainsKey($k)) { $cfg[$k] = $script:ConfigDefaults[$k] } }

    # A setup file is the phone's answer to "what are my URL and key", so it
    # lands before the command-line overrides: an explicit -RemoteUrl on the
    # same command line still wins.
    if ($SetupFile) {
        Write-Host ""
        Write-Host "  Import setup file" -ForegroundColor Cyan
        try {
            $imp = Import-Sync9RouterSetup -Path $SetupFile -Force:(-not $WhatIfPreference) -WhatIf:$WhatIfPreference
            foreach ($c in $imp.Changes) { Write-Host "    $c" -ForegroundColor Green }
            if ($imp.Changes.Count -eq 0) { Write-Host "    config sudah sama, tidak ada yang berubah" -ForegroundColor DarkGray }
            if ($WhatIfPreference) {
                Write-Host "    (-WhatIf: config tidak ditulis)" -ForegroundColor DarkGray
                $cfg["remoteUrl"] = $imp.RemoteUrl
                $cfg["bridgeKey"] = "x" * 64
            } else {
                $cfg = Get-Sync9RouterConfig
            }
        } catch {
            Write-Host ""
            Write-Err $_.Exception.Message
            exit 2
        }
    }

    if ($RemoteUrl)   { $cfg["remoteUrl"] = $RemoteUrl }
    if ($BridgeKey)   { $cfg["bridgeKey"] = $BridgeKey }
    if ($DefaultModel) { $cfg["defaultModel"] = $DefaultModel }
    if ($Tools.Count -gt 0) { $cfg["tools"] = $Tools }
    if ($BackupKeep -gt 0) { $cfg["backupKeep"] = $BackupKeep }

    # Refuse before any network call. An empty key otherwise surfaces as a bare
    # 401 from the bridge, which reads like a wrong key rather than a config
    # that was never filled in -- and this repo ships empty on purpose, so that
    # is the default state of every fresh clone.
    $missing = @()
    if (-not "$($cfg.remoteUrl)".Trim()) { $missing += "remoteUrl" }
    if (-not "$($cfg.bridgeKey)".Trim()) { $missing += "bridgeKey" }
    if ($missing.Count) {
        Write-Host ""
        Write-Err "Missing: $($missing -join ', ')"
        Write-Host ""
        Write-Host "  Cara tercepat -- biar HP yang menuliskan config-nya:" -ForegroundColor White
        Write-Host ""
        Write-Host "    1. Di Termux (HP):" -ForegroundColor White
        Write-Host "         bash termux/9router-bridge-export.sh" -ForegroundColor Gray
        Write-Host ""
        Write-Host "    2. Transfer 9sync-setup.local.md ke PC, lalu:" -ForegroundColor White
        Write-Host "         .\sync-9router.bat --cli -SetupFile <path>" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Cara manual:" -ForegroundColor White
        Write-Host "         .\sync-9router.bat   ->  menu 3 (Ubah pengaturan)" -ForegroundColor Gray
        Write-Host "    atau salin sync-9router.config.example.json" -ForegroundColor DarkGray
        Write-Host "    ke sync-9router.config.json lalu isi sendiri." -ForegroundColor DarkGray
        Write-Host ""
        exit 2
    }

    # A scheme-less remoteUrl is not a missing value, so it does not belong in
    # the list above, but it is the same class of mistake caught at the same
    # moment. Left alone the sync reports success and leaves five tool configs
    # pointing at a bare host:port that no tool can resolve.
    if (-not (Test-RemoteUrlScheme $cfg.remoteUrl)) {
        Write-Host ""
        Write-Err "remoteUrl harus diawali http:// atau https://, sekarang '$($cfg.remoteUrl)'."
        Write-Host ""
        Write-Host "  Contoh LAN    : http://192.168.1.42:20128" -ForegroundColor Gray
        Write-Host "  Contoh tunnel : https://<hostname>.ngrok-free.dev" -ForegroundColor Gray
        Write-Host ""
        exit 2
    }

    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host "  9Router CLI Tools Sync  ->  Windows PC                  " -ForegroundColor Magenta
    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host ""

    $res = Invoke-Sync9Router -Config $cfg -WhatIf:$WhatIfPreference

    Write-Host ""
    if (-not $res.Ok) {
        Write-Err $res.Error
        Write-Warn "Tidak ada file yang ditulis."
        Show-SyncReport $res
        Write-Host ""
        exit 1
    }
    Show-SyncReport $res
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Green
    if ($res.WhatIf) {
        Write-Host "  Preview selesai. Tidak ada file yang ditulis." -ForegroundColor Green
    } else {
        Write-Host "  Sync selesai. Endpoint: $($res.Endpoint)" -ForegroundColor Green
    }
    Write-Host "==========================================================" -ForegroundColor Green
    exit 0
}
