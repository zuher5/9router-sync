<#
    config.ps1 - config + state files.

    State records one run, from one place. The old code called Record-SyncRun
    from inside the engine AND again from the TUI wrapper, so every TUI-driven
    run was logged twice and, with the log capped at 20 entries, half the
    history was thrown away.
#>

$script:ConfigDefaults = [ordered]@{
    # Empty on purpose. The bridge key is a shared secret that lives only on the
    # phone running 9Router; the tunnel URL rotates on every restart. Neither
    # belongs in a file meant to be shared.
    remoteUrl    = ""
    bridgeKey    = ""
    defaultModel = ""
    tools        = @("opencode", "pi", "hermes", "claude", "codex")
    backupKeep   = 5
    urlHistory   = @()
}

# Order matters only for display. `omp` is not installed on this PC but stays
# registered so it shows up as available the moment it is.
$script:AllTools = @("opencode", "pi", "omp", "hermes", "claude", "codex")

# Paths are kept relative, and rooted at resolve time. An earlier version wrote
# "$env:LOCALAPPDATA\hermes\config.yaml" here, which PowerShell interpolated
# immediately, so the entry no longer matched the '$env:' prefix it was matched
# on later and got joined onto %USERPROFILE% instead.
$script:ToolMeta = [ordered]@{
    opencode = @{ Label = "OpenCode";    Root = "userprofile"; Files = @(".config\opencode\opencode.json"); Default = $true }
    pi       = @{ Label = "Pi";          Root = "userprofile"; Files = @(".pi\agent\models.json"); Default = $true }
    omp      = @{ Label = "Oh My Pi";    Root = "userprofile"; Files = @(".omp\agent\models.yml"); Default = $false }
    hermes   = @{ Label = "Hermes";      Root = "localappdata"; Files = @("hermes\config.yaml"); Default = $true }
    claude   = @{ Label = "Claude Code"; Root = "userprofile"; Files = @(".claude\settings.json"); Default = $true }
    codex    = @{ Label = "Codex";       Root = "userprofile"; Files = @(".codex\config.toml"); Default = $true }
}

function Get-ToolConfigPaths([string]$tool) {
    $meta = $script:ToolMeta[$tool]
    if (-not $meta) { return @() }
    # $env:LOCALAPPDATA rather than GetFolderPath: the latter reads the user's
    # real folder from the registry and ignores the variable, so a test sandbox
    # that sets it would still be pointed at the live config.
    $base = if ($meta.Root -eq "localappdata") {
        if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath("LocalApplicationData") }
    } else {
        $env:USERPROFILE
    }
    $out = @()
    foreach ($rel in $meta.Files) { $out += (Join-Path $base $rel) }
    return $out
}

# Presence is "can this tool be configured at all", which is not the same
# question as "does the file exist yet". Pi is installed by having its config
# directory; Claude and Codex only create their files on first run. Getting
# this backwards is why the dashboard claimed a tool was missing while the sync
# happily created the file.
function Get-ToolPresence {
    $out = [ordered]@{}
    foreach ($t in $script:AllTools) {
        $paths = @(Get-ToolConfigPaths $t)
        $installed = $false
        foreach ($p in $paths) {
            # Presence means "can this be configured at all", which is not the
            # same question as "does the file exist yet". Claude and Codex write
            # their config on first run, so a missing file still means installed.
            if ((Test-Path -LiteralPath $p) -or (Test-Path -LiteralPath (Split-Path -Parent $p))) {
                $installed = $true
                break
            }
        }
        $out[$t] = [pscustomobject]@{
            Tool = $t
            Label = $script:ToolMeta[$t].Label
            Paths = $paths
            PrimaryPath = $(if ($paths.Count -gt 0) { $paths[0] } else { "" })
            Installed = $installed
        }
    }
    return $out
}

# The bridge receiver compares with crypto.timingSafeEqual, which is byte-exact,
# so an uppercase hex key is a *different* key that comes back as a bare 401
# reading like "wrong key". Applied to every path that accepts one, including
# the -BridgeKey argument, which previously bypassed this entirely.
function Normalize-BridgeKey([string]$key) {
    return "$key".Trim().ToLowerInvariant()
}

# Invoke-WebRequest quietly assumes http for a bare host:port, so a URL without
# a scheme still reaches 9Router - and is then written verbatim into every tool
# config, where nothing makes that assumption and the tool cannot connect.
function Test-RemoteUrlScheme([string]$url) {
    return ("$url".Trim() -match '^https?://')
}

function Get-ConfigPath { return $script:ConfigPath }

function Get-StatePath { return (Join-Path $script:ScriptRoot "sync-9router.state.json") }

function Get-Config {
    $cfg = @{}
    foreach ($k in $script:ConfigDefaults.Keys) { $cfg[$k] = $script:ConfigDefaults[$k] }

    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        $j = ConvertTo-JsonOrNull (Read-ToolFile $path).Text
        if ($j) {
            foreach ($p in $j.PSObject.Properties) {
                if ($p.Name -eq "urlHistory") { $cfg["urlHistory"] = @($p.Value | Where-Object { $_ }) }
                else { $cfg[$p.Name] = $p.Value }
            }
        } else {
            Write-Warn "Config at $path could not be parsed, using defaults."
        }
    }

    if ($cfg["remoteUrl"]) { $cfg["remoteUrl"] = "$($cfg["remoteUrl"])".Trim().TrimEnd("/") }
    if ($cfg["bridgeKey"]) { $cfg["bridgeKey"] = Normalize-BridgeKey $cfg["bridgeKey"] }
    $cfg["urlHistory"] = @($cfg["urlHistory"] | Where-Object { $_ } | ForEach-Object { "$_".Trim().TrimEnd("/") })
    $cfg["tools"] = @($cfg["tools"] | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    $cfg["defaultModel"] = "$($cfg["defaultModel"])".Trim()
    try { $cfg["backupKeep"] = [int]$cfg["backupKeep"] } catch { $cfg["backupKeep"] = 5 }
    if ($cfg["backupKeep"] -lt 1 -or $cfg["backupKeep"] -gt 50) { $cfg["backupKeep"] = 5 }
    return $cfg
}

function Save-Config($cfg) {
    $out = [ordered]@{
        remoteUrl    = "$($cfg.remoteUrl)".Trim().TrimEnd("/")
        bridgeKey    = Normalize-BridgeKey "$($cfg.bridgeKey)"
        defaultModel = "$($cfg.defaultModel)".Trim()
        tools        = @($cfg.tools)
        backupKeep   = [int]$cfg.backupKeep
        urlHistory   = @($cfg.urlHistory)
    }
    $json = (ConvertTo-JsonText $out) + "`n"
    [System.IO.File]::WriteAllText((Get-ConfigPath), $json, (New-Object System.Text.UTF8Encoding($false)))
    return (Get-ConfigPath)
}

function Get-State {
    $p = Get-StatePath
    if (-not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ lastRun = $null; perTool = $null; modelHealth = $null; log = @() }
    }
    $j = ConvertTo-JsonOrNull (Read-ToolFile $p).Text
    if (-not $j) { return [pscustomobject]@{ lastRun = $null; perTool = $null; modelHealth = $null; log = @() } }
    $log = @()
    if ($j.PSObject.Properties.Name -contains "log") { $log = @($j.log | Where-Object { $_ }) }
    return [pscustomobject]@{
        lastRun = $(if ($j.PSObject.Properties.Name -contains "lastRun") { $j.lastRun } else { $null })
        perTool = $(if ($j.PSObject.Properties.Name -contains "perTool") { $j.perTool } else { $null })
        modelHealth = $(if ($j.PSObject.Properties.Name -contains "modelHealth") { $j.modelHealth } else { $null })
        log = $log
    }
}

function Save-State($state) {
    [System.IO.File]::WriteAllText((Get-StatePath), ((ConvertTo-JsonText $state) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Called exactly once per run, from exactly one place.
function Record-SyncRun($result, [switch]$WhatIf) {
    # A failed run is still a run. Recording only successes meant the dashboard
    # showed the last good result indefinitely, so a week of failures looked
    # identical to "has not been run".
    if ($WhatIf) { return }

    $state = Get-State
    $now = (Get-Date).ToString("MM-dd HH:mm")
    $perTool = [ordered]@{}

    foreach ($t in $script:AllTools) {
        $rows = @($result.Rows | Where-Object { $_.Tool -eq $t })
        if ($rows.Count -eq 0) { continue }
        $count = 0
        foreach ($c in $result.Changes) { if ($c.Tool -eq $t) { $count = $c.After } }
        $perTool[$t] = [pscustomobject]@{
            status     = (Resolve-ToolStatus $rows)
            modelCount = $count
            at         = $now
            paths      = @($rows | ForEach-Object { $_.Path })
        }
    }

    $psPerTool = [pscustomobject]@{}
    foreach ($k in $perTool.Keys) { $psPerTool | Add-Member -NotePropertyName $k -NotePropertyValue $perTool[$k] }

    $state.perTool = $psPerTool
    $state.lastRun = [pscustomobject]@{
        at           = (Get-Date).ToString("s")
        status       = $(if ($result.Ok) { "ok" } else { "fail" })
        endpoint     = $result.Endpoint
        modelCount   = @($result.ModelIds).Count
        defaultModel = $result.DefaultModel
        detail       = $(if ($result.Ok) { "" } else { "$($result.Error)" })
    }
    $entry = [pscustomobject]@{
        at      = (Get-Date).ToString("s")
        ok      = [bool]$result.Ok
        models  = @($result.ModelIds).Count
        default = $result.DefaultModel
        note    = $(if ($result.Ok) { "$(@($result.ModelIds).Count) models" } else { "$($result.Error)" })
    }
    $state.log = @($entry) + @($state.log)
    if ($state.log.Count -gt 40) { $state.log = @($state.log[0..39]) }

    try { Save-State $state } catch {
        if (-not $script:Quiet) { Write-Warn "State could not be saved: $($_.Exception.Message)" }
    }
}