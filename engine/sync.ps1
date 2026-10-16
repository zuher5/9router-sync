<#
    sync.ps1 - the engine.

    Dot-source it to get Invoke-Sync9Router and the helpers. Run it directly for
    a one-shot sync. There is no UI here; the web server in ../web calls
    Invoke-Sync9Router -Json and prints nothing but the JSON.

    .EXAMPLE
      .\engine\sync.ps1
    .EXAMPLE
      .\engine\sync.ps1 -Tools opencode,hermes -WhatIf
    .EXAMPLE
      .\engine\sync.ps1 -ListModels
    .EXAMPLE
      .\engine\sync.ps1 -PickDefault
    .EXAMPLE
      .\engine\sync.ps1 -Json
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RemoteUrl = "",
    [string]$BridgeKey = "",
    [string[]]$Tools = @(),
    [string]$DefaultModel = "",
    [int]$BackupKeep = 0,
    [string]$ConfigPath = "",
    [string]$SetupFile = "",
    [switch]$Json,
    [switch]$TestConnection,
    [switch]$ProbeModels,
    [switch]$PreviewModels,
    [switch]$ListModels,
    [switch]$PickDefault,
    [switch]$Diagnostics
)

$ErrorActionPreference = "Stop"
$script:DefaultRoot = Split-Path -Parent $PSScriptRoot
# The state file sits next to the config, not at a fixed path: with a custom
# -ConfigPath the two must travel together, or a test run writes its history
# into the user's real state file.
$script:ConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:DefaultRoot "sync-9router.config.json" }
$script:ScriptRoot = if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { $script:DefaultRoot }
$script:Quiet = $false
$script:Models = @()
$script:BackupKeep = 5

$RemoteUrl = "$RemoteUrl".Trim().TrimEnd("/")

. "$PSScriptRoot\lib\core.ps1"
. "$PSScriptRoot\lib\bridge.ps1"
. "$PSScriptRoot\lib\yaml-edit.ps1"
. "$PSScriptRoot\lib\toml-edit.ps1"
. "$PSScriptRoot\lib\resolve.ps1"
. "$PSScriptRoot\lib\config.ps1"
. "$PSScriptRoot\adapters\opencode.ps1"
. "$PSScriptRoot\adapters\pi.ps1"
. "$PSScriptRoot\adapters\omp.ps1"
. "$PSScriptRoot\adapters\hermes.ps1"
. "$PSScriptRoot\adapters\claude.ps1"
. "$PSScriptRoot\adapters\codex.ps1"

# Model ids 9Router has renamed, old id -> current id. Empty by default because a
# fresh install has nothing renamed yet.
$script:ModelAlias = @{}

# After loading, so the library is defined before anything normalizes against it.
$BridgeKey = Normalize-BridgeKey $BridgeKey

$script:AdapterFor = @{
    opencode = { Write-OpenCodeConfig $script:DefaultId }
    pi       = { Write-PiConfig $script:DefaultId }
    omp      = { Write-OmpConfig $script:DefaultId }
    hermes   = { Write-HermesConfig $script:DefaultId }
    claude   = { Write-ClaudeConfig }
    codex    = { Write-CodexConfig $script:DefaultId }
}

# Validation and per-tool probing, for the web UI. Both need a live bridge, so
# both are separate entry points rather than flags on the sync path.
function Test-Connection {
    param([string]$RemoteUrl, [string]$BridgeKey)
    $r = Test-BridgeUrl $RemoteUrl (Normalize-BridgeKey $BridgeKey) 12

    # Built as a fresh ordered dict rather than by Add-Member onto the probe
    # result: Test-BridgeUrl already returns a Note, and Add-Member without
    # -Force throws on an existing name.
    $out = [ordered]@{
        ok = $false
        ms = $r.Ms
        code = $r.Code
        note = $r.Note
        apiKeyOk = $false
        modelCount = 0
        catalogMs = 0
    }
    if ($r.Ok) {
        try {
            Set-Endpoint $RemoteUrl (Normalize-BridgeKey $BridgeKey)
            Connect-Bridge
            $out["apiKeyOk"] = $true
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $catalog = Get-ModelCatalog
            $sw.Stop()
            $out["modelCount"] = @($catalog).Count
            $out["catalogMs"] = $sw.ElapsedMilliseconds
            $out["ok"] = $true
        } catch {
            $out["note"] = "$($out["note"]); $($_.Exception.Message)"
        }
    }
    return $out
}

# "9router/vendor/model" and "vendor/model" name the same thing. The config
# stores whichever form the user picked, so the comparison strips the prefix
# on both sides instead of requiring an exact match.
function Strip-ProviderPrefix([string]$id) {
    $s = "$id".Trim()
    if ($s -match '^9router/(.+)$') { return $Matches[1] }
    return $s
}

# The models a sync would resolve, with the last known health of each. Purely
# informational: nothing is written.
#
# Each model carries `source`: the CLI tool on the phone whose config it came
# from. That is the answer to "where did this model come from", and it is what
# makes the list useful as a picker rather than just a dump.
function Get-ResolvedModelPreview {
    param($Config)
    $url = "$($Config.remoteUrl)".Trim().TrimEnd("/")
    $key = Normalize-BridgeKey "$($Config.bridgeKey)"
    if (-not (Test-RemoteUrlScheme $url) -or -not $key) {
        return [pscustomobject]@{ ok = $false; error = "Set the endpoint and bridge key first."; models = @(); skipped = @(); configuredDefault = ""; effectiveDefault = ""; sourceTools = @() }
    }
    try {
        Set-Endpoint $url $key
        $statuses = Get-BridgeJson "cli-tools/all-statuses"
        Connect-Bridge
        $catalog = Get-ModelCatalog
        $wanted = Collect-WantedModelIds $statuses
        if ($wanted.Ids.Count -eq 0) {
            return [pscustomobject]@{ ok = $false; error = "No 9router provider found in any CLI tool config on the phone."; models = @(); skipped = @(); configuredDefault = ""; effectiveDefault = ""; sourceTools = @() }
        }
        # Quiet, because Resolve-Models narrates every alias and skip and the
        # list itself is the message here.
        $wasQuiet = $script:Quiet
        $script:Quiet = $true
        try { $models = @(Resolve-Models $wanted.Ids $catalog $script:ModelAlias) }
        finally { $script:Quiet = $wasQuiet }

        # Effective default uses the same rule as the sync itself: an explicit
        # local default wins; an empty one follows the phone's configured
        # default; an unknown id falls back with a warning at sync time.
        # Showing it here is what lets the picker be trusted - the star marks
        # what the next sync will actually use.
        $configured = "$($Config.defaultModel)".Trim()
        $configuredStripped = Strip-ProviderPrefix $configured
        $ids = @($models | ForEach-Object { $_.id })
        $phoneDefault = ""
        if ($wanted.PhoneDefault -and @($wanted.PhoneDefault).Count -gt 0) { $phoneDefault = @($wanted.PhoneDefault)[0] }
        $effective = ""
        if ($models.Count -gt 0) {
            $candidate = if ($configured) { $configured } elseif ($phoneDefault) { $phoneDefault } else { $ids[0] }
            $candStripped = Strip-ProviderPrefix $candidate
            $found = $false
            foreach ($mid in $ids) {
                if ((Strip-ProviderPrefix $mid) -eq $candStripped) { $found = $true; break }
            }
            $effective = if ($found) { $candStripped } else { (Strip-ProviderPrefix $ids[0]) }
        }

        $health = (Get-State).modelHealth
        $out = @()
        foreach ($m in $models) {
            $h = $null
            if ($health -and ($health.PSObject.Properties.Name -contains $m.id)) { $h = $health.$m.id }
            $src = ""
            if ($wanted.Sources -and $wanted.Sources.ContainsKey($m.requestedAs)) { $src = $wanted.Sources[$m.requestedAs] }
            elseif ($wanted.Sources -and $wanted.Sources.ContainsKey($m.id)) { $src = $wanted.Sources[$m.id] }
            $stripped = Strip-ProviderPrefix $m.id
            $out += [pscustomobject]@{
                id = $m.id; ctx = $m.ctx; maxOut = $m.maxOut
                vision = $m.vision; reasoning = $m.reasoning; tools = $m.tools
                wasRenamed = $m.wasRenamed; requestedAs = $m.requestedAs
                source = $src
                isConfiguredDefault = [bool]($configured -and ($stripped -eq $configuredStripped))
                isEffectiveDefault = [bool]($effective -and ($stripped -eq $effective))
                healthOk = $(if ($h) { [bool]$h.ok } else { $null })
                healthAt = $(if ($h) { "$($h.at)" } else { "" })
                healthNote = $(if ($h) { "$($h.note)" } else { "" })
            }
        }

        # Ids the phone asked for that did not make the resolved list. With
        # mirror-as-is semantics this is normally only alias duplicates; the
        # preview lists them so the absence is visible instead of silent.
        $seenRequested = @($models | ForEach-Object { $_.requestedAs }) + @($models | ForEach-Object { $_.id })
        $resolvedIds = @($models | ForEach-Object { $_.id })
        $resolvedStripped = @($resolvedIds | ForEach-Object { Strip-ProviderPrefix $_ })
        $skipped = @()
        foreach ($wid in $wanted.Ids) {
            if ($seenRequested -contains $wid) { continue }
            $src = ""
            if ($wanted.Sources -and $wanted.Sources.ContainsKey($wid)) { $src = $wanted.Sources[$wid] }
            $reason = "not in the 9Router catalog and no alias"
            $target = $wid
            if ($script:ModelAlias -and $script:ModelAlias.ContainsKey($wid)) { $target = $script:ModelAlias[$wid] }
            if ($resolvedIds -contains $target) {
                $reason = "duplicate of included model '$target'"
            } elseif ($resolvedStripped -contains (Strip-ProviderPrefix $target)) {
                # The twin without the 9router/ prefix is in the list with
                # full capabilities; the prefixed form collapsed into it.
                $reason = "same model as included '$(Strip-ProviderPrefix $target)'"
            }
            $skipped += [pscustomobject]@{
                id = $wid; source = $src; reason = $reason
            }
        }

        return [pscustomobject]@{
            ok = $true; error = ""; models = @($out); skipped = @($skipped)
            configuredDefault = $configured; effectiveDefault = $effective
            sourceTools = @($wanted.ToolsUsed)
            probedAt = $(if ($health -and ($health.PSObject.Properties.Name -contains "__probe")) { "$($health.'__probe'.at)" } else { "" })
        }
    } catch {
        return [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)"; models = @(); skipped = @(); configuredDefault = ""; effectiveDefault = ""; sourceTools = @() }
    }
}

# Human-readable table for the terminal. The -PreviewModels flag stays machine
# readable (JSON) because the web server parses it; this is the version for eyes.
function Show-ModelPreview($preview) {
    if (-not $preview.ok) {
        Write-Host ""
        Write-Err $preview.error
        Write-Host ""
        return
    }
    $models = @($preview.models)
    Write-Host ""
    Write-Info "Models loaded from CLI tools ($($models.Count)):"
    if (@($preview.sourceTools).Count -gt 0) {
        Write-Detail "sources: $($preview.sourceTools -join ', ')"
    }
    if ($preview.configuredDefault) {
        Write-Info "Configured default: $($preview.configuredDefault)"
    } else {
        Write-Info "Configured default: (empty - 9Router decides)"
    }
    if ($preview.effectiveDefault) {
        Write-Info "Effective default:  $($preview.effectiveDefault)   <- what the next sync will use"
    }
    if ($preview.probedAt) {
        Write-Detail "health tags from the last check: $($preview.probedAt)"
    }
    Write-Host ""
    Write-Host ("    {0,-3} {1,-2} {2,-42} {3,-9} {4,-4} {5,-4} {6,-4} {7}" -f "#", "*", "MODEL", "CTX", "VIS", "RSN", "TOOL", "SOURCE") -ForegroundColor DarkGray
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $star = if ($m.isEffectiveDefault) { "*" } else { " " }
        $flags = @()
        if ($m.wasRenamed) { $flags += "renamed" }
        $color = if ($m.isEffectiveDefault) { "Green" } else { "Gray" }
        Write-Host ("    {0,-3} {1,-2} {2,-42} {3,-9} {4,-4} {5,-4} {6,-4} {7}" -f `
            ($i + 1), $star, $m.id, $m.ctx, $(if ($m.vision) { "yes" } else { "" }), `
            $(if ($m.reasoning) { "yes" } else { "" }), $(if ($m.tools) { "yes" } else { "no" }), $m.source) -ForegroundColor $color
        $hmark = ""
        if ($m.healthOk -eq $true) { $hmark = "health: ok" }
        elseif ($m.healthOk -eq $false) { $hmark = "health: FAILED ($($m.healthNote))" }
        if ($hmark -or $flags.Count -gt 0) {
            Write-Host ("         {0}" -f ((@($flags) + @($hmark) | Where-Object { $_ }) -join "  ")) -ForegroundColor DarkGray
        }
    }
    $skipped = @($preview.skipped)
    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Warn "Skipped (on the phone, not in the catalog):"
        foreach ($s in $skipped) {
            Write-Host ("      - $($s.id)   [from $($s.source)]  $($s.reason)") -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  * = effective default. Run with -PickDefault to change it." -ForegroundColor DarkGray
    Write-Host ""
}

# Interactive picker. Lists what a sync would resolve, takes a number, saves it
# to the config file. Nothing is synced here - the next sync applies it, which
# keeps "choose" and "apply" as two deliberate steps.
function Invoke-PickDefaultModel($cfg) {
    $preview = Get-ResolvedModelPreview $cfg
    if (-not $preview.ok) {
        Write-Host ""
        Write-Err $preview.error
        Write-Host ""
        return 1
    }
    Show-ModelPreview $preview

    $models = @($preview.models)
    Write-Host "  0 = clear (follow 9Router). Enter = cancel." -ForegroundColor DarkGray
    $ans = "$(Read-Host '  Select number')".Trim()
    if (-not $ans) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return 0 }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 0 -or $n -gt $models.Count) {
        Write-Host "  Not a number in range. Default unchanged." -ForegroundColor Yellow
        return 1
    }
    if ($n -eq 0) {
        $cfg["defaultModel"] = ""
        Save-Config $cfg | Out-Null
        Write-Host ""
        Write-Host "  Cleared. 9Router decides again." -ForegroundColor Green
        Write-Host "  Run a sync to apply it to the tool configs." -ForegroundColor DarkGray
        return 0
    }
    $pick = $models[$n - 1]
    # Stored stripped ("vendor/model" rather than "9router/vendor/model"): that
    # is the convention the config file already uses, and the sync strips a
    # prefix anyway, so both forms keep working.
    $cfg["defaultModel"] = (Strip-ProviderPrefix $pick.id)
    $p = Save-Config $cfg
    Write-Host ""
    Write-Host ("  Default model set to {0}  ({1})" -f $pick.id, $p) -ForegroundColor Green
    if ($pick.source) { Write-Host ("  Source: {0}" -f $pick.source) -ForegroundColor DarkGray }
    Write-Host "  Run a sync to apply it to the tool configs." -ForegroundColor DarkGray
    return 0
}

# Probes each model with one cheap completion and records the outcome, which is
# how a provider that has run out of credit shows up before it gets picked.
function Test-ResolvedModels {
    param($Config, [int]$TimeoutSec = 40)
    $url = "$($Config.remoteUrl)".Trim().TrimEnd("/")
    $key = Normalize-BridgeKey "$($Config.bridgeKey)"
    if (-not (Test-RemoteUrlScheme $url) -or -not $key) {
        return [pscustomobject]@{ ok = $false; error = "Set the endpoint and bridge key first."; results = @() }
    }
    try {
        Set-Endpoint $url $key
        Connect-Bridge
        $preview = Get-ResolvedModelPreview $Config
        if (-not $preview.ok) { return $preview }

        $results = @()
        foreach ($m in $preview.models) {
            $t = Test-ModelLive $m.id $TimeoutSec
            $results += [pscustomobject]@{
                id = $m.id; ok = $t.Ok; code = $t.Code; ms = $t.Ms; note = $t.Note
            }
        }
        $okCount = @($results | Where-Object { $_.ok }).Count

        $state = Get-State
        $health = [pscustomobject]@{}
        if ($state.modelHealth) {
            foreach ($p in $state.modelHealth.PSObject.Properties) {
                if ($p.Name -eq "__probe") { continue }
                $health | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
        foreach ($r in $results) {
            $health | Add-Member -NotePropertyName $r.id -NotePropertyValue ([pscustomobject]@{
                ok = $r.ok; code = $r.code; note = $r.note; at = (Get-Date).ToString("s")
            }) -Force
        }
        $health | Add-Member -NotePropertyName "__probe" -NotePropertyValue ([pscustomobject]@{
            ok = $okCount; total = $results.Count; at = (Get-Date).ToString("s")
        }) -Force
        $state.modelHealth = $health
        try { Save-State $state } catch {
            if (-not $script:Quiet) { Write-Warn "State could not be saved: $($_.Exception.Message)" }
        }

        return [pscustomobject]@{
            ok = $true; error = ""
            results = @($results)
            healthy = $okCount; total = @($results).Count
        }
    } catch {
        return [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)"; results = @() }
    }
}

function Invoke-Sync9Router {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string[]]$Tools = @(),
        [string]$DefaultModel = "",
        # Not called -WhatIf: SupportsShouldProcess already owns that name on
        # this function, and declaring it twice is a parse error.
        [switch]$DryRun,
        [switch]$Quiet
    )

    $script:Quiet = [bool]$Quiet
    $script:Report = @()
    $script:Changes = @()
    $script:Dangling = @()
    $script:Models = @()
    $script:ApiKey = ""
    $script:DefaultId = ""

    # Shared with Write-ToolFile so the write decision lives in one place.
    # -DryRun short-circuits it; otherwise the caller's own -WhatIf is honoured.
    $cmd = $PSCmdlet
    $dryRun = [bool]$DryRun
    $script:ShouldWrite = {
        param([string]$path)
        if ($dryRun) { return $false }
        return [bool]$cmd.ShouldProcess($path, "write")
    }

    $result = [ordered]@{
        ok = $false
        error = ""
        stage = ""
        endpoint = ""
        defaultModel = ""
        models = @()
        modelIds = @()
        rows = @()
        changes = @()
        dangling = @()
        whatIf = [bool]($DryRun -or $WhatIfPreference)
    }

    try {
        # --- preflight -----------------------------------------------------
        # Checked here, not only in the CLI entry point. The TUI and the web
        # server call this function directly, so anything validated outside it
        # was bypassed by every non-CLI caller.
        $url = "$($Config.remoteUrl)".Trim().TrimEnd("/")
        $key = Normalize-BridgeKey "$($Config.bridgeKey)"
        if (-not $url -or -not (Test-RemoteUrlScheme $url)) {
            throw "No endpoint configured. Set remoteUrl in Settings, or import the setup file the phone wrote."
        }
        if (-not $key) {
            throw "No bridge key configured. It is the 64-character hex value from '9router bridge' on the phone."
        }

        $requested = @()
        foreach ($t in @($Tools)) { $requested += @("$t" -split "," | ForEach-Object { $_.Trim() }) }
        if ($requested.Count -eq 0) { $requested = @($Config.tools | ForEach-Object { "$_" }) }
        $requested = @($requested | Where-Object { $_ })

        $unknown = @($requested | Where-Object { $script:AllTools -notcontains "$_" })
        if ($unknown.Count -gt 0) {
            # The old fallback was `if ($Tools.Count -eq 0) { $Tools = $script:AllTools }`,
            # so a single typo produced an empty list and every tool got synced
            # while the warning said the typo was skipped.
            throw "Unknown tool: $($unknown -join ', '). Valid tools are: $($script:AllTools -join ', ')."
        }
        $selected = @($requested | Where-Object { $script:AllTools -contains "$_" })
        if ($selected.Count -eq 0) { $selected = @($Config.tools | Where-Object { $script:AllTools -contains "$_" }) }
        if ($selected.Count -eq 0) { $selected = @($script:AllTools) }

        $script:BackupKeep = if ($BackupKeep -gt 0) { $BackupKeep } else { [int]$Config.backupKeep }
        if ($script:BackupKeep -lt 1 -or $script:BackupKeep -gt 50) { $script:BackupKeep = 5 }

        Set-Endpoint $url $key
        $result["endpoint"] = $script:ApiBase

        # --- connect -------------------------------------------------------
        $result["stage"] = "connect"
        if (-not $Quiet) { Write-Info "Connecting to $url" }
        $statuses = Get-BridgeJson "cli-tools/all-statuses"
        Write-Success "Bridge connected, auth ok."

        Connect-Bridge
        Write-Success "Got the 9Router API key."

        $result["stage"] = "catalog"
        if (-not $Quiet) { Write-Info "Fetching the model catalog" }
        $catalog = Get-ModelCatalog
        Write-Success "Catalog: $(@($catalog).Count) models."

        # --- resolve -------------------------------------------------------
        $result["stage"] = "resolve"
        $wanted = Collect-WantedModelIds $statuses
        if ($wanted.ToolsUsed.Count -gt 0 -and -not $Quiet) {
            Write-Detail "model sources: $($wanted.ToolsUsed -join ', ')"
        }
        if ($wanted.Ids.Count -eq 0) {
            throw "No models could be resolved: nothing in the 9Router CLI tool configs has a 9router provider."
        }
        $script:Models = Resolve-Models $wanted.Ids $catalog $script:ModelAlias
        if ($script:Models.Count -eq 0) {
            throw "No models could be resolved from the 9Router CLI tool configs."
        }

        if (-not $Quiet) {
            Write-Host ""
            Write-Info "Resolved models ($($script:Models.Count)):"
            foreach ($m in $script:Models) {
                Write-Detail ("{0,-42} ctx={1,-8} maxOut={2,-7} vision={3,-5} reasoning={4} tools={5}" -f `
                    $m.id, $m.ctx, $m.maxOut, $m.vision, $m.reasoning, $m.tools)
            }
        }

        # --- default model -------------------------------------------------
        # Model ids carry provider segments, so an id can arrive as either
        # "9router/vendor/model" or "vendor/model". Both are accepted; the
        # comparison happens before the prefix is stripped, because stripping
        # first made the stripped form look absent from the list and the
        # fallback then handed back the prefixed id.
        $dm = if ($DefaultModel) { "$DefaultModel" } else { "$($Config.defaultModel)" }
        $dm = $dm.Trim()
        if (-not $dm) {
            # An empty local default means "whatever 9Router has configured",
            # not "first in the resolved list".
            $pd = @()
            if ($wanted.PhoneDefault) { $pd = @($wanted.PhoneDefault) }
            $dm = if ($pd.Count -gt 0) { $pd[0] } else { @($script:Models)[0].id }
        }

        $ids = @($script:Models | ForEach-Object { $_.id })
        # Compared stripped on both sides, like the preview does: explicit
        # defaults and pins can arrive as 9router/X while the resolved entry
        # is X (or the reverse for mirrored entries). The old one-directional
        # check fell back to the first model with a warning.
        $strippedIds = @($ids | ForEach-Object { Strip-ProviderPrefix $_ })
        $matchesId = {
            param($cand)
            ($ids -contains $cand) -or ($strippedIds -contains (Strip-ProviderPrefix $cand))
        }
        if (-not (& $matchesId $dm)) {
            $fallback = $ids[0]
            Write-Warn "Default '$dm' is not in the resolved list, using '$fallback'."
            $dm = $fallback
        }
        # Stripped once, here, for every writer.
        if ($dm -match '^9router/(.+)$') { $dm = $Matches[1] }
        $script:DefaultId = $dm
        $result["defaultModel"] = $dm
        if (-not $Quiet) {
            Write-Host ""
            Write-Info "Default model: $dm"
            Write-Host ""
        }

        # --- write ---------------------------------------------------------
        # Each adapter is isolated. One tool throwing does not take the others
        # with it, and the run reports both the failure and everything that did
        # land - rather than claiming nothing was written when three files had
        # already changed.
        $result["stage"] = "write"
        $failures = @()
        foreach ($t in $selected) {
            try {
                & $script:AdapterFor[$t]
            } catch {
                $msg = "$($_.Exception.Message)"
                Write-Err "$t -> $msg"
                Add-Report $t "" "failed" $msg
                $failures += $t
            }
        }

        $result["ok"] = ($failures.Count -eq 0)
        if ($failures.Count -gt 0) {
            $result["error"] = "$($failures.Count) tool(s) failed: $($failures -join ', ')"
        }

        $result["models"] = @($script:Models)
        $result["modelIds"] = $ids
        $result["rows"] = @($script:Report)
        $result["changes"] = @($script:Changes)
        $result["dangling"] = @($script:Dangling)
    } catch {
        $result["ok"] = $false
        $result["error"] = "$($_.Exception.Message)"
    }

    return $result
}

function Get-ToolDiagnostics {
    $presence = Get-ToolPresence
    $out = @()
    foreach ($t in $script:AllTools) {
        $p = $presence[$t]
        $out += [pscustomobject]@{
            tool = $t
            label = $p.Label
            installed = $p.Installed
            paths = @($p.Paths)
            exists = @($p.Paths | Where-Object { Test-Path -LiteralPath $_ })
        }
    }
    return $out
}

# --- CLI entry point ------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $cfg = Get-Config
    if ($RemoteUrl) { $cfg["remoteUrl"] = $RemoteUrl }
    if ($BridgeKey) { $cfg["bridgeKey"] = $BridgeKey }
    if ($DefaultModel) { $cfg["defaultModel"] = $DefaultModel }
    if ($BackupKeep -gt 0) { $cfg["backupKeep"] = $BackupKeep }

    if ($TestConnection) {
        $t = Test-Connection $cfg["remoteUrl"] $cfg["bridgeKey"]
        Write-Output (ConvertTo-JsonText $t)
        exit $(if ($t["ok"] -and $t["apiKeyOk"]) { 0 } else { 1 })
    }

    if ($ProbeModels) {
        $p = Test-ResolvedModels $cfg
        Write-Output (ConvertTo-JsonText ([ordered]@{
            ok = $p.ok; error = $p.error
            healthy = $(if ($p.PSObject.Properties.Name -contains "healthy") { $p.healthy } else { 0 })
            total = $(if ($p.PSObject.Properties.Name -contains "total") { $p.total } else { 0 })
            results = @($p.results)
        }))
        exit $(if ($p.ok) { 0 } else { 1 })
    }

    if ($PreviewModels) {
        $v = Get-ResolvedModelPreview $cfg
        Write-Output (ConvertTo-JsonText ([ordered]@{
            ok = $v.ok; error = $v.error; models = @($v.models)
            skipped = @($v.skipped)
            configuredDefault = "$($v.configuredDefault)"
            effectiveDefault = "$($v.effectiveDefault)"
            sourceTools = @($v.sourceTools)
            probedAt = $(if ($v.PSObject.Properties.Name -contains "probedAt") { $v.probedAt } else { "" })
        }))
        exit $(if ($v.ok) { 0 } else { 1 })
    }

    if ($ListModels) {
        Show-ModelPreview (Get-ResolvedModelPreview $cfg)
        exit 0
    }

    if ($PickDefault) {
        $code = Invoke-PickDefaultModel $cfg
        exit $code
    }

    if ($Diagnostics) {
        # Everything a bug report needs, with the secrets removed. A 64-hex
        # bridge key and any API key are masked; everything else is safe to paste
        # into an issue.
        $masked = [ordered]@{
            remoteUrl = "$($cfg.remoteUrl)"
            bridgeKey = (Mask-Secret "$($cfg.bridgeKey)")
            defaultModel = "$($cfg.defaultModel)"
            tools = @($cfg.tools)
            backupKeep = [int]$cfg.backupKeep
            urlHistory = @($cfg.urlHistory)
        }
        $versions = [ordered]@{}
        $versions["node"] = (& node --version 2>$null) -join ""
        $versions["powershell"] = "$($PSVersionTable.PSVersion)"
        $versions["os"] = "$([System.Environment]::OSVersion.VersionString)"

        # $toolList, not $tools: PowerShell variables are case-insensitive, so
        # $tools here would be the [string[]]$Tools parameter and every ordered
        # dictionary would be coerced to the string "System.Collections...".
        $toolList = @()
        foreach ($t in Get-ToolDiagnostics) {
            $toolList += [ordered]@{
                tool = $t.tool; label = $t.label; installed = $t.installed
                paths = @($t.paths); exists = @($t.exists)
            }
        }
        $state = Get-State
        Write-Output (ConvertTo-JsonText ([ordered]@{
            version = "9sync engine"
            config = $masked
            tools = @($toolList)
            versions = $versions
            lastRun = $state.lastRun
            log = @($state.log)
            statePath = (Get-StatePath)
            configPath = (Get-ConfigPath)
        }))
        exit 0
    }

    $res = Invoke-Sync9Router -Config $cfg -Tools $Tools -DryRun:$WhatIfPreference -Quiet:$Json
    Record-SyncRun $res -WhatIf:$WhatIfPreference

    if ($Json) {
        # Single JSON document on stdout, nothing else. The web server reads this
        # and nothing else, so the two can never disagree about what happened.
        Write-Output (ConvertTo-JsonText $res)
        exit $(if ($res.ok) { 0 } else { 1 })
    }

    if (-not $res.ok) {
        Write-Host ""
        Write-Err $res.error
        if (@($res.rows).Count -gt 0) {
            Write-Host ""
            Write-Host "  What did happen:" -ForegroundColor Yellow
            foreach ($r in $res.rows) { Write-Host ("    {0,-10} {1,-14} {2}" -f $r.Tool, $r.Status, $r.Detail) -ForegroundColor DarkGray }
        }
        exit 1
    }

    Write-Host ""
    Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
    foreach ($r in $res.rows) {
        Write-Host ("  {0,-10} {1,-14} {2}" -f $r.Tool, $r.Status, $r.Detail)
    }
    Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray

    if (@($res.changes).Count -gt 0) {
        Write-Host ""
        Write-Host "  Model changes:" -ForegroundColor Cyan
        foreach ($c in $res.changes) {
            $parts = @()
            if (@($c.Added).Count -gt 0)   { $parts += "+$(@($c.Added).Count) ($($c.Added -join ', '))" }
            if (@($c.Removed).Count -gt 0) { $parts += "-$(@($c.Removed).Count) ($($c.Removed -join ', '))" }
            if ($parts.Count -gt 0) { Write-Host ("    {0,-10} {1} -> {2}   {3}" -f $c.Tool, $c.Before, $c.After, ($parts -join "  ")) -ForegroundColor Green }
        }
    }
    if (@($res.dangling).Count -gt 0) {
        Write-Host ""
        Write-Host "  Released pins (model no longer in 9Router):" -ForegroundColor Yellow
        foreach ($d in $res.dangling) { Write-Host ("    {0,-10} {1,-28} -> {2}" -f $d.Tool, $d.Where, $d.Model) -ForegroundColor Yellow }
    }

    Write-Host ""
    if ($res.whatIf) { Write-Host "  Preview done. No files were written." -ForegroundColor Cyan }
    else { Write-Host "  Sync done. Endpoint: $($res.endpoint)" -ForegroundColor Green }
    exit 0
}