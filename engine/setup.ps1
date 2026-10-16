<#
    setup.ps1 - one-time verification of the phone-side setup file.

    Kept as a separate entry point rather than folded into the engine: importing
    a file that contains a secret is a deliberate act, not something a plain sync
    should ever do on its own.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$SetupFile,
    [string]$ConfigPath = "",
    # Also apply defaultModel, tools and backupKeep. Off by default so a phone
    # that names a different tool set cannot silently overwrite a list the user
    # has already curated.
    [switch]$Force
    # No -WhatIf parameter here: SupportsShouldProcess already owns that name,
    # and declaring it a second time is a parse error.
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\core.ps1"
. "$PSScriptRoot\lib\config.ps1"

$root = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $root "sync-9router.config.json" }
$script:ScriptRoot = if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { $root }

function Read-SetupFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Setup file not found: $path" }
    $info = Read-ToolFile $path
    if ([string]::IsNullOrWhiteSpace($info.Text)) { throw "Setup file is empty: $path" }

    # Fenced block tagged `9sync`. The closing fence may be indented or carry
    # trailing spaces, so the tag and the fence are matched independently.
    $m = [regex]::Match($info.Text, '(?s)```9sync\s*\r?\n(.*?)\r?\n```')
    if (-not $m.Success) {
        # "9sync" without the fences: PowerShell's own error formatting mangles a
        # triple backtick in a message into an unreadable single quote.
        throw ("No 9sync block in " + $path + ". It has to be written by 9router-bridge-export.sh in Termux.")
    }
    try { return ($m.Groups[1].Value | ConvertFrom-Json) }
    catch { throw ("The 9sync block in " + $path + " is not valid JSON: " + $_.Exception.Message) }
}

function Test-SetupValues($setup) {
    $problems = @()
    if ($null -eq $setup) { return @("The setup block is JSON null.") }

    $url = ""
    if ($setup.PSObject.Properties.Name -contains "remoteUrl") { $url = "$($setup.remoteUrl)".Trim() }
    $key = if ($setup.PSObject.Properties.Name -contains "bridgeKey") { Normalize-BridgeKey "$($setup.bridgeKey)" } else { "" }

    if (-not $url) {
        $problems += "remoteUrl is empty. An ngrok tunnel URL or http://<LAN-IP>:20128 is required."
    } elseif ($url -notmatch '^https?://') {
        $problems += "remoteUrl has to start with http:// or https://, but it is '$url'."
    }
    if (-not $key) {
        $problems += "bridgeKey is empty. Run '9router bridge' in Termux, then run the export script again."
    } elseif ($key -notmatch '^[0-9a-f]{64}$') {
        # The length, never the value: a wrong paste must not end up echoed into
        # a log or a screenshot. An off-by-one is almost always a dropped
        # character, not a rotated key - and the two look identical from here.
        $problems += "bridgeKey has to be 64 hex characters, but the import has $($key.Length). A length that is off usually means a character was lost in a copy-paste."
    }
    return $problems
}

$setup = Read-SetupFile $SetupFile
$problems = Test-SetupValues $setup

Write-Host ""
Write-Host "  Setup file: $SetupFile" -ForegroundColor Cyan
Write-Host ("  remoteUrl    {0}" -f $(if ($setup -and ($setup.PSObject.Properties.Name -contains "remoteUrl") -and $setup.remoteUrl) { $setup.remoteUrl } else { "(empty)" })) -ForegroundColor White
$klen = if ($setup -and ($setup.PSObject.Properties.Name -contains "bridgeKey")) { "$($setup.bridgeKey)".Trim().Length } else { 0 }
Write-Host ("  bridgeKey    {0} characters (value not shown)" -f $klen) -ForegroundColor White
$dm = if ($setup -and ($setup.PSObject.Properties.Name -contains "defaultModel")) { "$($setup.defaultModel)" } else { "" }
Write-Host ("  defaultModel {0}" -f $(if ($dm) { $dm } else { "(follow 9Router)" })) -ForegroundColor Gray
$tl = @()
if ($setup -and ($setup.PSObject.Properties.Name -contains "tools")) { $tl = @($setup.tools | Where-Object { $_ }) }
Write-Host ("  tools        {0}" -f $(if ($tl.Count) { $tl -join ", " } else { "(empty)" })) -ForegroundColor Gray
Write-Host ""

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "  [X] $p" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Config untouched." -ForegroundColor Yellow
    exit 2
}

$cfg = Get-Config
$newUrl = "$($setup.remoteUrl)".Trim().TrimEnd("/")
$newKey = Normalize-BridgeKey "$($setup.bridgeKey)"
$changes = @()
if ("$($cfg.remoteUrl)".TrimEnd("/") -ne $newUrl) { $changes += "remoteUrl: '$($cfg.remoteUrl)' -> '$newUrl'" }
if ((Normalize-BridgeKey "$($cfg.bridgeKey)") -ne $newKey) { $changes += "bridgeKey: replaced (new key from the phone)" }

# Kept out of the config file on purpose: the bridge key is a shared secret
# that only exists on the phone, and this file is meant to be shareable.
$history = @($cfg.urlHistory | Where-Object { $_ -and $_ -ne $newUrl })
$cfg["urlHistory"] = @($newUrl) + @($history)
if (@($cfg.urlHistory).Count -gt 6) { $cfg["urlHistory"] = @($cfg.urlHistory)[0..5] }
$cfg["remoteUrl"] = $newUrl
$cfg["bridgeKey"] = $newKey

if ($Force) {
    if (($setup.PSObject.Properties.Name -contains "defaultModel")) {
        $dmNew = "$($setup.defaultModel)".Trim()
        if ($dmNew -ne "$($cfg.defaultModel)".Trim()) { $changes += "defaultModel: '$($cfg.defaultModel)' -> '$dmNew'" }
        $cfg["defaultModel"] = $dmNew
    }
    $tlNew = @()
    if ($setup.PSObject.Properties.Name -contains "tools") { $tlNew = @($setup.tools | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToLowerInvariant() }) }
    $tlNew = @($tlNew | Where-Object { $script:AllTools -contains $_ })
    if ($tlNew.Count -gt 0 -and ($tlNew -join ",") -ne (@($cfg.tools) -join ",")) {
        $changes += "tools: '$(@($cfg.tools) -join ', ')' -> '$($tlNew -join ', ')'"
        $cfg["tools"] = $tlNew
    }
    if (($setup.PSObject.Properties.Name -contains "backupKeep")) {
        $bkNew = 0
        if ([int]::TryParse("$($setup.backupKeep)", [ref]$bkNew) -and $bkNew -ge 1 -and $bkNew -le 50) {
            if ($bkNew -ne [int]$cfg.backupKeep) { $changes += "backupKeep: $($cfg.backupKeep) -> $bkNew" }
            $cfg["backupKeep"] = $bkNew
        }
    }
}

if ($PSCmdlet.ShouldProcess((Get-ConfigPath), "write config from setup file")) {
    Save-Config $cfg | Out-Null
    if ($changes.Count -eq 0) {
        Write-Host "  Config was already identical." -ForegroundColor DarkGray
    } else {
        foreach ($c in $changes) { Write-Host "  $c" -ForegroundColor Green }
    }
    Write-Host ("  Saved: {0}" -f (Get-ConfigPath)) -ForegroundColor Green
} else {
    Write-Host "  (-WhatIf: config not written)" -ForegroundColor DarkGray
    foreach ($c in $changes) { Write-Host "  would change: $c" -ForegroundColor Cyan }
}

Write-Host ""
Write-Host "  This file holds a password. Delete it once you are done:" -ForegroundColor Yellow
Write-Host ("    {0}" -f $SetupFile) -ForegroundColor DarkGray
exit 0