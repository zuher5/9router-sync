<#
.SYNOPSIS
  TUI for sync-9router.ps1.

.DESCRIPTION
  Menu-driven console front end. Dot-sources the sync script for its logic, so
  there is only one implementation of the sync itself.

  Drawn with ASCII only. Box drawing characters depend on the console code page
  and this tool is launched from a .bat through powershell.exe, where that is not
  something to rely on.

.EXAMPLE
  .\sync-9router-tui.ps1
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$script:TuiConfigPath = $ConfigPath
. "$PSScriptRoot\sync-9router.ps1" -ConfigPath $script:TuiConfigPath

# ---------------------------------------------------------------------------
# Menu definition
# ---------------------------------------------------------------------------

$script:Menu = @(
    @{ Key = "1"; Label = "Sync now";            Hint = "pull models & endpoints from 9Router" },
    @{ Key = "2"; Label = "Preview (dry run)";    Hint = "see changes without writing files" },
    @{ Key = "3"; Label = "Settings";             Hint = "URL, bridge key, default model, tools, backups" },
    @{ Key = "4"; Label = "Test connection";     Hint = "bridge alive? auth valid?" },
    @{ Key = "5"; Label = "Test models";         Hint = "smoke test each model" },
    @{ Key = "6"; Label = "Validate configs";    Hint = "parse YAML/JSON + check model pins" },
    @{ Key = "7"; Label = "Run history";          Hint = "last 20 syncs" },
    @{ Key = "8"; Label = "Restore backup";       Hint = "revert config from .bak" },
    @{ Key = "9"; Label = "Manage URLs";          Hint = "test all URLs, adopt working one" },
    @{ Key = "I"; Label = "Import phone setup";   Hint = "read 9sync-setup.local.md from Termux" },
    @{ Key = "0"; Label = "Quit";                Hint = "" }
)
$script:QuitIndex = 10

# The menu is drawn as a fixed two-column grid, filled down the first column
# then the second. Its geometry used to be a literal 5 in six places, split
# across the renderer and the key handler, which agreed only because there
# happened to be exactly 10 items. With 11 items the renderer put the extra
# one on a row that does not exist while the key handler put it on row 0, so
# the highlight stopped matching the drawing, and UpArrow near the end indexed
# past the end of the array. One helper, one source of truth.
$script:MenuCols = 2
# Items per column, which is the row count. The last column is usually short.
$script:Rows = [int][Math]::Ceiling($script:Menu.Count / $script:MenuCols)
$script:ColCount = $script:MenuCols

function Get-MenuCell([int]$index) {
    return [pscustomobject]@{
        Col = [int][Math]::Floor($index / $script:Rows)
        Row = $index % $script:Rows
    }
}

# Moves a selection by one step, staying inside the grid. A move that would land
# on a cell with no item in it is dropped rather than clamped, so a keypress in
# an empty corner does nothing instead of jumping to an unrelated item.
function Move-Selection([int]$from, [string]$key) {
    $cell = Get-MenuCell $from
    $col = $cell.Col
    $row = $cell.Row
    $target = -1

    # The column to try when a vertical move runs off the end of this one:
    # the one to the right if it exists, otherwise the one to the left.
    $other = if ($col + 1 -lt $script:ColCount) { $col + 1 } elseif ($col -gt 0) { $col - 1 } else { -1 }

    switch ($key) {
        "UpArrow" {
            if ($row -gt 0) { $target = $from - 1 }
            elseif ($other -ge 0) { $target = ($other * $script:Rows) + $row }
        }
        "DownArrow" {
            if ($row -lt $script:Rows - 1) { $target = $from + 1 }
            elseif ($other -ge 0) { $target = ($other * $script:Rows) + $row }
        }
        "LeftArrow"  { if ($col -gt 0)                 { $target = (($col - 1) * $script:Rows) + $row } }
        "RightArrow" { if ($col + 1 -lt $script:ColCount) { $target = (($col + 1) * $script:Rows) + $row } }
        "Home"       { $target = $col * $script:Rows }
        "End"        { $target = [Math]::Min((($col + 1) * $script:Rows) - 1, $script:Menu.Count - 1) }
    }

    if ($target -lt 0 -or $target -ge $script:Menu.Count) { return $from }
    return $target
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Clear-Screen { Clear-Host }

function Write-Rule([string]$ch = "=", [int]$n = 74) { Write-Host ($ch * $n) -ForegroundColor DarkGray }

function Write-Title([string]$t) {
    Write-Host "  9Router Sync  >  Windows PC" -ForegroundColor Magenta
    Write-Host "  $t" -ForegroundColor DarkGray
}

$script:StatusColor = @{ updated = "Green"; unchanged = "DarkGray"; skipped = "Yellow"; failed = "Red"; whatif = "Cyan"; "not-installed" = "DarkYellow" }

# A bridge key prefix is only ever a prefix. The length is clamped because the
# shipped default is an empty string, and Substring on that threw, taking the
# dashboard down for anyone who had not filled the config in yet.
function Format-BridgeKey([string]$k) {
    $s = "$k".Trim()
    if (-not $s) { return "(not set)" }
    if ($s.Length -le 16) { return $s }
    return $s.Substring(0, 16) + "..."
}

function Get-StatusColor([string]$s) {
    if ($script:StatusColor.ContainsKey($s)) { return $script:StatusColor[$s] }
    return "Gray"
}

# Reads one keypress without echoing. Falls back to Read-Host when the console
# is redirected, which is what happens if the TUI is launched from a pipeline.
function Read-Key {
    try { return [Console]::ReadKey($true) } catch { return $null }
}

# Read-Host returns $null at end of input, so every answer is stringified before
# trimming. Without that, a closed stdin turns a prompt into a crash.
function Ask([string]$prompt) {
    return "$(Read-Host $prompt)".Trim()
}

function Wait-Enter([string]$msg = "Press Enter to return to menu") {
    Write-Host ""
    Write-Host "  $msg ..." -ForegroundColor DarkGray
    $k = Read-Key
    if ($null -eq $k) { $null = Read-Host }
}

# ngrok free hostnames rotate on every tunnel restart, so a dead URL is the
# normal case rather than an error, and the useful thing to show is which
# candidate answers and how fast.
function Format-Url([string]$u) {
    $s = "$u".TrimEnd("/")
    if ($s.Length -gt 52) { $s = $s.Substring(0, 25) + "..." + $s.Substring($s.Length - 24) }
    return $s
}

function Show-Dashboard($cfg, $state, [int]$sel) {
    Clear-Screen
    Write-Rule
    Write-Title "status & menu"
    Write-Rule

    $health = $state.modelHealth
    $lineStatus = "not checked yet"
    $lineColor = "DarkGray"
    if ($health -and ($health.PSObject.Properties.Name -contains "__probe")) {
        $p = $health.'__probe'
        $lineStatus = "$($p.ok)/$($p.total) models healthy"
        $lineColor = if ($p.ok -eq $p.total) { "Green" } elseif ($p.ok -gt 0) { "Yellow" } else { "Red" }
    }

    Write-Host ""
    Write-Host ("  Endpoint    {0}" -f (Format-Url $cfg.remoteUrl)) -ForegroundColor White
    Write-Host ("  Bridge key  {0}" -f (Format-BridgeKey $cfg.bridgeKey)) -ForegroundColor DarkGray
    Write-Host ("  Default     {0}" -f $(if ($cfg.defaultModel) { $cfg.defaultModel } else { "default (9Router)" })) -ForegroundColor DarkGray
    Write-Host ("  Tools       {0}" -f (@($cfg.tools) -join ", ")) -ForegroundColor DarkGray
    Write-Host ("  Health      {0}" -f $lineStatus) -ForegroundColor $lineColor

    $lr = $state.lastRun
    if ($lr) {
        Write-Host ("  Last sync   {0}  {1} models  ({2})" -f $lr.at, $lr.modelCount, $lr.status) -ForegroundColor DarkGray
    } else {
        Write-Host ("  Last sync   never" ) -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("  {0,-10} {1,5}  {2,-14} {3,-8} {4}" -f "TOOL", "MODELS", "STATUS", "UPDATED", "ON PC") -ForegroundColor DarkGray
    # "ON PC" answers the question a fresh clone raises first: is this tool even
    # installed here? A tool that is absent reports not-installed, which is a
    # fact about the machine rather than a sync failure.
    $presence = Get-ToolPresence
    foreach ($t in @("opencode", "omp", "hermes", "claude", "codex")) {
        $here = "yes"
        $hereColor = "DarkGray"
        if ($presence.Contains($t) -and -not $presence[$t].Exists) { $here = "no"; $hereColor = "DarkYellow" }
        $pt = $null
        if ($state.perTool -and ($state.perTool.PSObject.Properties.Name -contains $t)) { $pt = $state.perTool.$t }
        if ($pt) {
            $mc = if ($null -ne $pt.modelCount -and $pt.modelCount -gt 0) { "$($pt.modelCount)" } else { "-" }
            $at = if ($pt.at) { $pt.at } else { "-" }
            Write-Host ("  {0,-10} {1,5}  {2,-14} {3,-8} " -f $t, $mc, $pt.status, $at) -NoNewline -ForegroundColor (Get-StatusColor $pt.status)
        } else {
            Write-Host ("  {0,-10} {1,5}  {2,-14} {3,-8} " -f $t, "-", "never", "-") -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ("{0}" -f $here) -ForegroundColor $hereColor
    }

    Write-Host ""
    Write-Rule "-"
    $selCell = Get-MenuCell $sel
    for ($i = 0; $i -lt $script:Rows; $i++) {
        $idxA = $i
        $idxB = $script:Rows + $i
        $a = if ($idxA -lt $script:Menu.Count) { $script:Menu[$idxA] } else { $null }
        $b = if ($idxB -lt $script:Menu.Count) { $script:Menu[$idxB] } else { $null }
        $rowSel = ($selCell.Row -eq $i)
        $ca = if ($rowSel) { "Black" } else { "Gray" }
        $cb = if ($rowSel) { "Black" } else { "Gray" }
        $bg = if ($rowSel) { "Cyan" } else { "DarkGray" }
        $ma = if (($selCell.Col -eq 0) -and $rowSel) { ">" } else { " " }
        $mb = if (($selCell.Col -eq 1) -and $rowSel) { ">" } else { " " }
        # One Write-Host per cell with -NoNewline, otherwise each call ends the
        # line and the two columns stack instead of sitting side by side.
        if ($a) {
            Write-Host (" {0}[{1}] {2,-20}" -f $ma, $a.Key, $a.Label) -NoNewline -ForegroundColor $ca -BackgroundColor $bg
        }
        if ($b) {
            Write-Host (" {0}[{1}] {2}" -f $mb, $b.Key, $b.Label) -ForegroundColor $cb -BackgroundColor $bg
        } else {
            Write-Host ""
        }
    }
    Write-Rule "-"
    Write-Host ""
    Write-Host "  Arrow keys move   Enter selects   Number/Letter selects directly" -ForegroundColor DarkGray
    Write-Host "  Pure ASCII characters, safe on cmd.exe / PowerShell ISE / Windows Terminal" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Bridge helpers
# ---------------------------------------------------------------------------

function Add-UrlHistory($cfg, [string]$url) {
    $u = "$url".TrimEnd("/")
    if (-not $u) { return }
    $h = @(@($cfg.urlHistory | Where-Object { $_ -and $_ -ne $u }))
    $cfg["urlHistory"] = @($u) + $h
    if ($cfg.urlHistory.Count -gt 6) { $cfg["urlHistory"] = @($cfg.urlHistory)[0..5] }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

function Save-RunState($cfg, $res) {
    # The core records the run itself, so both the CLI and the TUI leave the same
    # state behind. Kept as a thin wrapper so the action code reads uniformly.
    if ($res.Ok -and -not $res.WhatIf) { Record-SyncRun $cfg $res }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Show-SyncResult($res) {
    if (-not $res.Ok) {
        Write-Host ""
        Write-Host "  [X] $($res.Error)" -ForegroundColor Red
        Write-Host "  No files were written." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    foreach ($r in $res.Rows) {
        Write-Host ("  {0,-9} {1,-10} {2}" -f $r.Tool, $r.Status, $r.Detail) -ForegroundColor (Get-StatusColor $r.Status)
    }

    $moved = @($res.Changes | Where-Object { $_.Added.Count -gt 0 -or $_.Removed.Count -gt 0 })
    if ($moved.Count -gt 0) {
        Write-Host ""
        Write-Host "  Model changes summary:" -ForegroundColor Cyan
        foreach ($c in $moved) {
            $parts = @()
            if ($c.Added.Count -gt 0)   { $parts += "+$($c.Added.Count)  $($c.Added -join ', ')" }
            if ($c.Removed.Count -gt 0) { $parts += "-$($c.Removed.Count)  $($c.Removed -join ', ')" }
            Write-Host ("    {0,-9} {1} -> {2}   {3}" -f $c.Tool, $c.Before, $c.After, ($parts -join "   ")) -ForegroundColor Green
        }
    }
    if ($res.Dangling.Count -gt 0) {
        Write-Host ""
        Write-Host "  Unpinned models (no longer in 9Router):" -ForegroundColor Yellow
        foreach ($d in $res.Dangling) {
            Write-Host ("    {0,-9} {1,-26} -> {2}" -f $d.Tool, $d.Where, $d.Model) -ForegroundColor Yellow
        }
    }
    if ($res.OutOfSync.Count -gt 0) {
        Write-Host ""
        Write-Host "  Outside sync list, left untouched (direct base_url):" -ForegroundColor DarkGray
        foreach ($o in $res.OutOfSync) { Write-Host ("    {0,-9} {1}" -f $o.Tool, $o.Model) -ForegroundColor DarkGray }
    }

    Write-Host ""
    if ($res.WhatIf) {
        Write-Host "  Preview complete. No files were written." -ForegroundColor Cyan
    } else {
        Write-Host "  Done. $($res.ModelIds.Count) models, default $($res.DefaultModel)" -ForegroundColor Green
    }
}

function Invoke-ActionSync($cfg, [switch]$WhatIf) {
    Clear-Screen
    Write-Rule
    Write-Title $(if ($WhatIf) { "preview - no files written" } else { "sync from 9Router" })
    Write-Rule
    Write-Host ""
    $res = Invoke-Sync9Router -Config $cfg -WhatIf:$WhatIf
    Show-SyncResult $res
    if (-not $WhatIf -or $res.Ok) { Save-RunState $cfg $res }
    Wait-Enter
}

function Invoke-ActionTestConnection($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "test connection"
    Write-Rule
    Write-Host ""

    $r = Test-BridgeUrl $cfg.remoteUrl $cfg.bridgeKey 12
    if ($r.Ok) {
        Write-Host ("  bridge     OK   {0} ms   {1}" -f $r.Ms, (Format-Url $cfg.remoteUrl)) -ForegroundColor Green
    } else {
        Write-Host ("  bridge     FAILED  {0}   {1}" -f $r.Note, (Format-Url $cfg.remoteUrl)) -ForegroundColor Red
        Write-Host ""
        Write-Host "  If 404, ngrok URL has rotated. Select [9] Manage URLs." -ForegroundColor Yellow
        Wait-Enter
        return
    }

    try {
        Connect-Bridge $cfg
        Write-Host ("  auth       OK   API key active" ) -ForegroundColor Green
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cat = Get-ModelCatalog
        $sw.Stop()
        Write-Host ("  catalog    {0} models   {1} ms" -f @($cat).Count, $sw.ElapsedMilliseconds) -ForegroundColor Green
    } catch {
        Write-Host ("  auth       FAILED  {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Wait-Enter
}

# Smoke tests the models the PC config actually points at, which is the set the
# tools will try to call. A provider that has run out of credit only shows up
# here, not in a model list.
function Invoke-ActionTestModels($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "smoke test models"
    Write-Rule
    Write-Host ""

    $ocPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    $ids = @()
    $src = ""
    $oc = Read-JsonOrNull $ocPath
    if ($oc) { $ids = @(Get-OpenCodeModelIds $oc) }
    if ($ids.Count -eq 0) {
        $ompLines = Read-LinesOrEmpty (Join-Path $env:USERPROFILE ".omp\agent\models.yml")
        $ids = @(Get-OmpModelIds $ompLines)
        if ($ids.Count -gt 0) { $src = "omp models.yml" }
    } else {
        $src = "opencode.json"
    }
    if ($ids.Count -eq 0) {
        Write-Host "  No models configured in PC files. Run sync first." -ForegroundColor Yellow
        Wait-Enter
        return
    }
    Write-Host ("  Source: {0}   ({1} models)" -f $src, $ids.Count) -ForegroundColor DarkGray
    Write-Host "  40s timeout per model: cold providers can be slow on first call," -ForegroundColor DarkGray
    Write-Host "  this does not mean model is broken." -ForegroundColor DarkGray
    Write-Host ""

    try { Connect-Bridge $cfg } catch {
        Write-Host ("  [X] $($_.Exception.Message)" ) -ForegroundColor Red
        Wait-Enter
        return
    }

    $state = Get-Sync9RouterState
    $health = [pscustomobject]@{}
    $nOk = 0
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $id = $ids[$i]
        Write-Host ("  [{0}/{1}] {2,-44}" -f ($i + 1), $ids.Count, $id) -NoNewline
        $t = Test-ModelLive $id 40
        if ($t.Ok) { $nOk++; Write-Host ("  OK     {0,5} ms" -f $t.Ms) -ForegroundColor Green }
        else       { Write-Host ("  FAILED {0,5} ms" -f $t.Ms) -ForegroundColor Red }
        Write-Host ("           {0}" -f $t.Note) -ForegroundColor DarkGray
        $health | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{
            ok = $t.Ok; code = $t.Code; note = $t.Note; at = (Get-Date).ToString("s")
        }) -Force
    }
    $health | Add-Member -NotePropertyName "__probe" -NotePropertyValue ([pscustomobject]@{
        ok = $nOk; total = $ids.Count; at = (Get-Date).ToString("s")
    }) -Force
    $state.modelHealth = $health
    Save-Sync9RouterState $state

    Write-Host ""
    if ($nOk -eq $ids.Count) { Write-Host "  All models healthy." -ForegroundColor Green }
    elseif ($nOk -eq 0)      { Write-Host "  No models responded. Check provider credits on 9Router." -ForegroundColor Red }
    else                     { Write-Host "  $nOk of $($ids.Count) healthy. Check remaining models on 9Router." -ForegroundColor Yellow }
    Wait-Enter
}

function Invoke-ActionValidate($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "validate config files"
    Write-Rule
    Write-Host ""

    $py = Get-Command python -ErrorAction SilentlyContinue
    $scriptFile = $null
    if ($py) {
        $scriptFile = Join-Path $env:TEMP "opencode\_yamlcheck.py"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $scriptFile) | Out-Null
        $pycode = @"
import sys
try:
    import yaml
except ImportError:
    print('NOPYAML'); sys.exit(0)
try:
    yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
    print('OK')
except Exception as e:
    print('ERR ' + str(e).replace(chr(10), ' | ')[:160])
"@
        [System.IO.File]::WriteAllText($scriptFile, $pycode, (New-Object System.Text.UTF8Encoding($false)))
    }

    $pass = 0; $fail = 0; $skip = 0
    $ocPath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"

    $targets = @(
        @{ Tool = "opencode"; Path = $ocPath; Kind = "json" }
        @{ Tool = "omp";      Path = (Join-Path $env:USERPROFILE ".omp\agent\models.yml"); Kind = "yaml" }
        @{ Tool = "omp";      Path = (Join-Path $env:USERPROFILE ".omp\agent\config.yml"); Kind = "yaml" }
        @{ Tool = "hermes";   Path = (Join-Path $env:LOCALAPPDATA "hermes\config.yaml"); Kind = "yaml" }
        @{ Tool = "claude";   Path = (Join-Path $env:USERPROFILE ".claude\settings.json"); Kind = "json" }
        @{ Tool = "codex";    Path = (Join-Path $env:USERPROFILE ".codex\config.toml"); Kind = "toml" }
    )

    foreach ($t in $targets) {
        $name = Split-Path -Leaf $t.Path
        if (-not (Test-Path -LiteralPath $t.Path)) {
            Write-Host ("  {0,-9} {1,-18} missing" -f $t.Tool, $name) -ForegroundColor DarkGray
            $skip++; continue
        }
        $raw = Read-TextUtf8 $t.Path
        $bom = ([System.IO.File]::ReadAllBytes($t.Path)[0..2])
        $hasBom = ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)

        $note = ""
        $ok = $true
        if ($t.Kind -eq "json") {
            try { $null = $raw | ConvertFrom-Json } catch { $ok = $false; $note = $_.Exception.Message.Split("`n")[0] }
            if ($ok) { $note = "JSON valid" }
        } elseif ($t.Kind -eq "yaml") {
            # Tabs are illegal as YAML indentation, and a tab sneaks in easily
            # when a block is rewritten by hand.
            if ($raw -match "(?m)^\t") { $ok = $false; $note = "tab found at line start" }
            if ($ok -and $py -and $scriptFile) {
                $out = (& $py.Source $scriptFile $t.Path 2>&1 | Out-String).Trim()
                if ($out -eq "OK") { $note = "YAML valid" }
                elseif ($out -eq "NOPYAML") { $ok = $true; $note = "pyyaml not installed, basic check only"; $skip++ }
                else { $ok = $false; $note = $out }
            } else {
                $note = "YAML, basic check only"
            }
        } else {
            $note = "TOML, basic check only"
        }

        if ($hasBom) { $note += "  [BOM PRESENT]"; if ($ok) { $ok = $false } }
        if ($ok) { Write-Host ("  {0,-9} {1,-18} {2}" -f $t.Tool, $name, $note) -ForegroundColor Green; $pass++ }
        else       { Write-Host ("  {0,-9} {1,-18} {2}" -f $t.Tool, $name, $note) -ForegroundColor Red; $fail++ }
    }

    # Cross-file check: a pin that names a model the provider no longer publishes
    # is the failure mode that only shows up when the agent is actually used.
    Write-Host ""
    $oc = Read-JsonOrNull $ocPath
    if ($oc) {
        $ids = @(Get-OpenCodeModelIds $oc)
        Write-Host "  Model pins in opencode.json:" -ForegroundColor Cyan

        # Every agent model is classified, including pins to other providers, so
        # it is visible that they were recognised and deliberately left alone.
        $entries = @()
        if ($oc.model) {
            $entries += [pscustomobject]@{ Where = "model"; Raw = $oc.model }
        }
        if ($oc.agents) {
            foreach ($a in $oc.agents.PSObject.Properties) {
                $v = $a.Value
                if ($v -and ($v.PSObject.Properties.Name -contains "model") -and $v.model) {
                    $entries += [pscustomobject]@{ Where = "agents.$($a.Name)"; Raw = $v.model }
                }
            }
        }
        foreach ($e in $entries) {
            $prov = $null; $mname = $null
            if ($e.Raw -is [string]) {
                $s = "$($e.Raw)"
                if ($s -match '^([^/]+)/(.+)$') { $prov = $Matches[1]; $mname = $Matches[2] } else { $mname = $s }
            } else {
                $prov = "$($e.Raw.providerID)"; $mname = "$($e.Raw.model)"
            }
            if ($prov -ne "9router") {
                Write-Host ("    {0,-20} {1}/{2}   other provider, untouched" -f $e.Where, $prov, $mname) -ForegroundColor DarkGray
            } elseif ($ids -contains $mname) {
                Write-Host ("    {0,-20} 9router/{1}  in catalog" -f $e.Where, $mname) -ForegroundColor Green
            } else {
                Write-Host ("    {0,-20} 9router/{1}  DANGLING - not in catalog" -f $e.Where, $mname) -ForegroundColor Red
                $fail++
            }
        }
    }

    Write-Host ""
    Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
    Wait-Enter
}

function Invoke-ActionHistory($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "run history"
    Write-Rule
    Write-Host ""
    $state = Get-Sync9RouterState
    $log = @($state.log)
    if ($log.Count -eq 0) {
        Write-Host "  No history yet. Run sync once." -ForegroundColor DarkGray
    } else {
        Write-Host ("  {0,-20} {1,-6} {2,-6} {3}" -f "TIMESTAMP", "RESULT", "MODELS", "NOTE") -ForegroundColor DarkGray
        foreach ($e in $log) {
            $c = if ($e.ok) { "Green" } else { "Red" }
            $n = "$($e.note)"
            if ($n.Length -gt 40) { $n = $n.Substring(0, 40) + "..." }
            Write-Host ("  {0,-20} {1,-6} {2,-6} {3}" -f $e.at, $(if ($e.ok) { "OK" } else { "FAILED" }), $e.models, $n) -ForegroundColor $c
        }
    }
    Wait-Enter
}

function Invoke-ActionRestore {
    Clear-Screen
    Write-Rule
    Write-Title "restore backup"
    Write-Rule
    Write-Host ""

    $paths = @(
        (Join-Path $env:USERPROFILE ".config\opencode\opencode.json")
        (Join-Path $env:USERPROFILE ".omp\agent\models.yml")
        (Join-Path $env:USERPROFILE ".omp\agent\config.yml")
        (Join-Path $env:LOCALAPPDATA "hermes\config.yaml")
        (Join-Path $env:LOCALAPPDATA "hermes\.env")
        (Join-Path $env:USERPROFILE ".claude\settings.json")
        (Join-Path $env:USERPROFILE ".codex\config.toml")
    )

    $items = @()
    foreach ($p in $paths) {
        $dir = Split-Path -Parent $p
        $leaf = Split-Path -Leaf $p
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $baks = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.*.bak" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($b in $baks) { $items += [pscustomobject]@{ File = $b.FullName; Target = $p; When = $b.Name } }
    }

    if ($items.Count -eq 0) {
        Write-Host "  No backups found." -ForegroundColor DarkGray
        Wait-Enter
        return
    }

    Write-Host "  Each file keeps multiple versions. Choose which one to restore." -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $stamp = ($it.When -replace [regex]::Escape((Split-Path -Leaf $it.Target) + "."), "") -replace "\.bak$", ""
        $sz = (Get-Item -LiteralPath $it.File).Length
        Write-Host ("  [{0,2}] {1,-20} {2,-16} {3,7} bytes" -f ($i + 1), (Split-Path -Leaf $it.Target), $stamp, $sz) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  [0] cancel" -ForegroundColor DarkGray
    $ans = Ask "  Select number"
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) {
        Write-Host "  Cancelled." -ForegroundColor DarkGray
        Wait-Enter
        return
    }
    $pick = $items[$n - 1]

    $stamp2 = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $pick.Target -Destination "$($pick.Target).$stamp2.bak" -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $pick.File -Destination $pick.Target -Force
    Write-Host ""
    Write-Host ("  Restored: {0}" -f (Split-Path -Leaf $pick.Target)) -ForegroundColor Green
    Write-Host ("  Current version saved as .{0}.bak" -f $stamp2) -ForegroundColor DarkGray
    Write-Host "  Run [6] Validate configs to ensure file parses." -ForegroundColor DarkGray
    Wait-Enter
}

# The URL screen exists because ngrok free hostnames rotate on every tunnel
# restart: a 404 from yesterday is the normal state, not a fault to debug.
function Invoke-ActionUrls($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "manage URLs"
    Write-Rule
    Write-Host ""
    Write-Host "  Free ngrok URLs rotate on restart. Test candidates one by one," -ForegroundColor DarkGray
    Write-Host "  then adopt the responsive one. Local LAN IP never changes." -ForegroundColor DarkGray
    Write-Host ""

    $cands = @()
    $cur = "$($cfg.remoteUrl)".TrimEnd("/")
    $cands += $cur
    foreach ($u in @($cfg.urlHistory)) {
        $t = "$u".TrimEnd("/")
        if ($t -and $cands -notcontains $t) { $cands += $t }
    }

    $results = @()
    for ($i = 0; $i -lt $cands.Count; $i++) {
        Write-Host ("  [{0}] {1,-54}" -f ($i + 1), (Format-Url $cands[$i])) -NoNewline
        $r = Test-BridgeUrl $cands[$i] $cfg.bridgeKey 8
        if ($r.Ok) { Write-Host (" OK    {0,5} ms" -f $r.Ms) -ForegroundColor Green }
        else      { Write-Host (" {0,-16}" -f $r.Note) -ForegroundColor Red }
        $results += $r
    }

    Write-Host ""
    Write-Host "  [$(($cands.Count + 1))] enter new URL" -ForegroundColor Gray
    Write-Host "  [$(($cands.Count + 2))] LAN mode: http://<PHONE-IP>:20128 (no tunnel)" -ForegroundColor Gray
    Write-Host "  [0] back" -ForegroundColor DarkGray
    $ans = Ask "  Select"
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n)) { return }

    $newUrl = ""
    if ($n -ge 1 -and $n -le $cands.Count) {
        $pick = $results[$n - 1]
        if ($pick.Ok) { $newUrl = $pick.Url }
        else {
            Write-Host "  URL is not responding. Not applied." -ForegroundColor Yellow
            Wait-Enter
            return
        }
    } elseif ($n -eq ($cands.Count + 1)) {
        $u = Ask "  New URL (https://... or http://IP:20128)"
        if ($u) { $newUrl = $u.TrimEnd("/") }
    } elseif ($n -eq ($cands.Count + 2)) {
        $ip = Ask "  Phone IP on same Wi-Fi"
        if ($ip) { $newUrl = "http://${ip}:20128" }
    } else {
        return
    }

    if (-not $newUrl) { return }

    Write-Host ""
    Write-Host ("  Testing {0} ..." -f (Format-Url $newUrl)) -ForegroundColor Cyan
    $v = Test-BridgeUrl $newUrl $cfg.bridgeKey 12
    if (-not $v.Ok) {
        Write-Host ("  FAILED: {0}" -f $v.Note) -ForegroundColor Red
        Write-Host "  Kept existing URL." -ForegroundColor DarkGray
        Wait-Enter
        return
    }
    $cfg["remoteUrl"] = $newUrl
    Add-UrlHistory $cfg $newUrl
    Save-Sync9RouterConfig $cfg | Out-Null
    Write-Host ("  OK, auth valid. Active URL: {0}" -f (Format-Url $newUrl)) -ForegroundColor Green
    Write-Host "  Run [1] Sync now to apply." -ForegroundColor DarkGray
    Wait-Enter
}

function Invoke-ActionSettings($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "settings"
    Write-Rule
    Write-Host ""
    Write-Host "  Leave empty to keep current value." -ForegroundColor DarkGray
    Write-Host ""

    $url = Ask "  Endpoint URL  [$($cfg.remoteUrl)]"
    if ($url) { $cfg["remoteUrl"] = $url.TrimEnd("/") }

    $cur = "$($cfg.bridgeKey)".Trim()
    $curHint = if (-not $cur) { "empty" } elseif ($cur.Length -le 8) { $cur } else { $cur.Substring(0, 8) + "..." }
    $bk = Ask "  Bridge key    [$curHint]"
    if ($bk) { $cfg["bridgeKey"] = $bk.Trim() }

    $dm = Ask "  Default model [$(if ($cfg.defaultModel) { $cfg.defaultModel } else { 'default (9Router)' })]"
    if ($dm) { $cfg["defaultModel"] = $dm }

    Write-Host ""
    Write-Host "  Tools to sync. Type name to toggle, Enter when done:" -ForegroundColor Gray
    $sel = @{}
    foreach ($t in @("opencode", "omp", "hermes", "claude", "codex")) { $sel[$t] = (@($cfg.tools) -contains $t) }
    while ($true) {
        $line = "   "
        foreach ($t in @("opencode", "omp", "hermes", "claude", "codex")) {
            $line += "[{0}]{1} " -f $(if ($sel[$t]) { "x" } else { " " }), $t
        }
        Write-Host $line -ForegroundColor White
        $a = Ask "  toggle tool (type name, or press Enter)"
        if (-not $a) { break }
        $a = $a.ToLower()
        if ($sel.ContainsKey($a)) { $sel[$a] = -not $sel[$a] }
        else { Write-Host "  Unknown tool: $a" -ForegroundColor Yellow }
    }
    $newTools = @()
    foreach ($t in @("opencode", "omp", "hermes", "claude", "codex")) { if ($sel[$t]) { $newTools += $t } }
    if ($newTools.Count -eq 0) {
        Write-Host "  At least one tool must be selected. Tools unchanged." -ForegroundColor Yellow
    } else {
        $cfg["tools"] = $newTools
    }

    $bkp = Ask "  Backups to keep per file [$($cfg.backupKeep)]"
    if ($bkp) {
        $n = 0
        if ([int]::TryParse($bkp, [ref]$n) -and $n -ge 1 -and $n -le 50) { $cfg["backupKeep"] = $n }
        else { Write-Host "  Invalid number, skipped." -ForegroundColor Yellow }
    }

    Add-UrlHistory $cfg $cfg.remoteUrl
    $p = Save-Sync9RouterConfig $cfg
    Write-Host ""
    Write-Host ("  Saved: {0}" -f $p) -ForegroundColor Green
    Wait-Enter
}

# Reads the file the phone wrote. The point of this is not to avoid typing a
# 64-character hex string, it is to avoid the class of mistake where one
# character is wrong and the only symptom is a 401 that looks like a wrong key.
function Invoke-ActionImportSetup($cfg) {
    Clear-Screen
    Write-Rule
    Write-Title "import phone setup"
    Write-Rule
    Write-Host ""
    Write-Host "  On Termux (phone), run:" -ForegroundColor White
    Write-Host "    bash termux/9router-bridge-export.sh" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Transfer 9sync-setup.local.md to PC and provide path." -ForegroundColor DarkGray
    Write-Host ""

    $in = Ask "  Setup file path"
    if (-not $in) { Write-Host "  Cancelled." -ForegroundColor DarkGray; Wait-Enter; return }
    $in = $in.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $in)) {
        Write-Host ""
        Write-Err "File not found: $in"
        Wait-Enter
        return
    }

    # Show what is in the file before anything is written, so a wrong file is
    # caught here rather than after the config has been overwritten.
    try {
        $setup = Read-SetupFile $in
    } catch {
        Write-Host ""
        Write-Err $_.Exception.Message
        Wait-Enter
        return
    }

    $problems = Test-SetupValues $setup
    Write-Host ""
    Write-Host ("  remoteUrl    {0}" -f "$(if ($setup.remoteUrl) { $setup.remoteUrl } else { '(empty)' })") -ForegroundColor White
    $klen = "$(if ($setup.bridgeKey) { "$($setup.bridgeKey)".Trim() } else { '' })".Length
    Write-Host ("  bridgeKey    {0} characters" -f $klen) -ForegroundColor White
    $dmu = "$(if ($setup.PSObject.Properties['defaultModel']) { $setup.defaultModel })"
    Write-Host ("  defaultModel {0}" -f $(if ($dmu) { $dmu } else { "default (9Router)" })) -ForegroundColor DarkGray
    $tl = @()
    if ($setup.PSObject.Properties['tools']) { $tl = @($setup.tools) }
    Write-Host ("  tools        {0}" -f $(if ($tl.Count) { $tl -join ", " } else { "(empty)" })) -ForegroundColor DarkGray
    Write-Host ""

    if ($problems.Count) {
        foreach ($p in $problems) { Write-Err $p }
        Write-Host ""
        Write-Host "  Config untouched." -ForegroundColor Yellow
        Wait-Enter
        return
    }

    $a1 = Ask "  Apply remoteUrl + bridgeKey? (y/n)"
    if ($a1 -notmatch '^(y|yes)$') { Write-Host "  Cancelled." -ForegroundColor DarkGray; Wait-Enter; return }

    $a2 = Ask "  Also apply defaultModel/tools/backupKeep? (y/n)"
    $force = ($a2 -match '^(y|yes)$')

    try {
        $imp = Import-Sync9RouterSetup -Path $in -Force:$force
    } catch {
        Write-Host ""
        Write-Err $_.Exception.Message
        Wait-Enter
        return
    }

    Write-Host ""
    if ($imp.Changes.Count -eq 0) {
        Write-Host "  Config identical, nothing changed." -ForegroundColor DarkGray
    } else {
        foreach ($c in $imp.Changes) { Write-Host "  $c" -ForegroundColor Green }
    }
    Write-Host ("  Applied: remoteUrl, bridgeKey{0}" -f $(if ($force) { ", defaultModel, tools, backupKeep" } else { "" })) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Setup file is still on disk. Delete when done:" -ForegroundColor Yellow
    Write-Host ("    {0}" -f $in) -ForegroundColor DarkGray
    Wait-Enter

    # The caller keeps a reference to $cfg, so reloading keeps the in-memory
    # copy in step with what was just written.
    $fresh = Get-Sync9RouterConfig
    foreach ($k in $fresh.Keys) { $cfg[$k] = $fresh[$k] }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

$sel = 0
while ($true) {
    $cfg = Get-Sync9RouterConfig
    $state = Get-Sync9RouterState
    Show-Dashboard $cfg $state $sel

    $idx = -1
    $k = Read-Key
    if ($null -ne $k) {
        $keyName = "$($k.Key)"
        switch ($keyName) {
            "UpArrow"    { $sel = Move-Selection $sel $keyName; continue }
            "DownArrow"  { $sel = Move-Selection $sel $keyName; continue }
            "LeftArrow"  { $sel = Move-Selection $sel $keyName; continue }
            "RightArrow" { $sel = Move-Selection $sel $keyName; continue }
            "Home"       { $sel = Move-Selection $sel $keyName; continue }
            "End"        { $sel = Move-Selection $sel $keyName; continue }
            "Enter"      { $idx = $sel }
            default      {
                # Menu keys are matched case-insensitively, so "i" and "I" both
                # reach the import item.
                for ($i = 0; $i -lt $script:Menu.Count; $i++) {
                    if ($script:Menu[$i].Key -eq $keyName) { $idx = $i }
                    elseif ($script:Menu[$i].Key -eq $keyName.ToUpperInvariant()) { $idx = $i }
                }
            }
        }
    } else {
        # Console is redirected, so there is no key to read. Fall back to typing
        # the number. Read-Host returns $null at end of input, hence the quotes
        # around every expansion here.
        $ans = "$(Read-Host '  Select number (0 = quit)')".Trim()
        if ($ans -eq "" -or $ans -eq "q" -or $ans -eq "0") { break }
        for ($i = 0; $i -lt $script:Menu.Count; $i++) {
            if ($script:Menu[$i].Key -eq $ans) { $idx = $i }
        }
    }

    if ($idx -lt 0) { continue }
    $sel = $idx
    if ($sel -eq $script:QuitIndex) { break }
    $item = $script:Menu[$sel]

    switch ($item.Label) {
        "Sync now"             { Invoke-ActionSync $cfg }
        "Preview (dry run)"    { Invoke-ActionSync $cfg -WhatIf }
        "Settings"             { Invoke-ActionSettings $cfg }
        "Test connection"      { Invoke-ActionTestConnection $cfg }
        "Test models"          { Invoke-ActionTestModels $cfg }
        "Validate configs"     { Invoke-ActionValidate $cfg }
        "Run history"          { Invoke-ActionHistory $cfg }
        "Restore backup"       { Invoke-ActionRestore }
        "Manage URLs"          { Invoke-ActionUrls $cfg }
        "Import phone setup"   { Invoke-ActionImportSetup $cfg }
    }
}

Clear-Screen
Write-Host ""
Write-Host "  9Router Sync - finished." -ForegroundColor Cyan
Write-Host ""
