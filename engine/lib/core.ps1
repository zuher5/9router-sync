<#
    core.ps1 - encoding-safe IO, JSON serialization, reporting primitives.

    Loaded by sync.ps1. Nothing here knows about 9Router or about any
    individual CLI tool.

    Every read returns the encoding it actually decoded with, and every write
    uses that same encoding back. The previous version decoded everything as
    UTF-8 regardless: a file authored in the ANSI codepage came back with
    U+FFFD where the byte 0x92 was, and the rewrite baked that replacement
    character permanently into the user's config.
#>

function Get-YamlIndent([string]$line) {
    return $line.Length - $line.TrimStart(" ").Length
}

# --- reporting -------------------------------------------------------------

$script:Report   = @()
$script:Changes  = @()
$script:Dangling = @()
$script:Notes    = @()

# Overridden by the engine so the WhatIf decision lives in one place. Defaults
# to writing, which is what unit tests want when they exercise a writer.
if (-not $script:ShouldWrite) {
    $script:ShouldWrite = { param([string]$path) return $true }
}

function Write-Info([string]$m)    { if (-not $script:Quiet) { Write-Host "[*] $m" -ForegroundColor Cyan } }
function Write-Success([string]$m) { if (-not $script:Quiet) { Write-Host "[OK] $m" -ForegroundColor Green } }
function Write-Warn([string]$m)    { if (-not $script:Quiet) { Write-Host "[!] $m" -ForegroundColor Yellow } }
function Write-Err([string]$m)     { if (-not $script:Quiet) { Write-Host "[X] $m" -ForegroundColor Red } }
function Write-Detail([string]$m)  { if (-not $script:Quiet) { Write-Host "    $m" -ForegroundColor DarkGray } }

# Statuses in precedence order, worst first. Record-SyncRun used to take the
# last row it happened to see, so omp reported "skipped" even though models.yml
# had just been rewritten - the row order, not the severity, decided the answer.
$script:StatusSeverity = @("failed", "updated", "skipped", "whatif", "unchanged", "not-installed")

function Add-Report([string]$tool, [string]$path, [string]$status, [string]$detail) {
    $script:Report += [pscustomobject]@{
        tool = $tool; path = $path; status = $status; detail = $detail
    }
}

# Collapses several rows for one tool into the single status worth showing.
function Resolve-ToolStatus($rows) {
    $seen = @{}
    foreach ($r in $rows) { $seen[$r.Status] = $true }
    foreach ($s in $script:StatusSeverity) {
        if ($seen.ContainsKey($s)) { return $s }
    }
    return "unchanged"
}

function Add-Change([string]$tool, [string]$path, [string[]]$before, [string[]]$after) {
    $b = @{}; foreach ($m in $before) { if ($m) { $b[$m] = $true } }
    $a = @{}; foreach ($m in $after)  { if ($m) { $a[$m] = $true } }
    $removed = @($before | Where-Object { $_ -and -not $a.ContainsKey($_) })
    $added   = @($after  | Where-Object { $_ -and -not $b.ContainsKey($_) })
    $script:Changes += [pscustomobject]@{
        tool = $tool; path = $path
        before = @($before | Where-Object { $_ }).Count
        after  = @($after  | Where-Object { $_ }).Count
        added = $added; removed = $removed
    }
}

function Add-Dangling([string]$tool, [string]$where, [string]$model) {
    $script:Dangling += [pscustomobject]@{ tool = $tool; where = $where; model = $model }
}

# What Write-ToolFile returns -> the status vocabulary the UI and state file use.
# Enough to tell two keys apart in a bug report, never enough to use one. The
# bridge key is a password with read/write access to the 9Router instance, and
# the diagnostics endpoint is meant to be pasteable.
function Mask-Secret([string]$secret) {
    $s = "$secret".Trim()
    if (-not $s) { return "(empty)" }
    if ($s.Length -le 8) { return ("*" * $s.Length) }
    return $s.Substring(0, 4) + ("*" * 12) + $s.Substring($s.Length - 4)
}

function ConvertTo-WriteStatus([string]$result) {
    switch ($result) {
        "written"   { return "updated" }
        "unchanged" { return "unchanged" }
        default     { return "whatif" }
    }
}

# --- encoding-safe file IO -------------------------------------------------

function Read-ToolFile([string]$path) {
    $info = @{
        Path = $path; Exists = $false; Text = ""; Encoding = "utf-8"; IsUtf8 = $true
    }
    if (-not (Test-Path -LiteralPath $path)) { return $info }
    $info["Exists"] = $true

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -eq 0) { return $info }

    # BOM check. A BOM is stripped here and never written back, because plain
    # [Text.Encoding]::UTF8 emits one and some TOML/JSON readers reject it.
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $start = 3
    }

    $slice = [byte[]]::new($bytes.Length - $start)
    [Array]::Copy($bytes, $start, $slice, 0, $slice.Length)

    # Strict UTF-8 first. If that throws the file was never UTF-8, and decoding
    # it as UTF-8 anyway would replace every invalid byte with U+FFFD - turning
    # a readable config into a corrupted one on the next write.
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $info["Text"] = $strict.GetString($slice)
        $info["IsUtf8"] = $true
    } catch {
        $info["Text"] = [System.Text.Encoding]::GetEncoding(1252).GetString($slice)
        $info["IsUtf8"] = $false
        $info["Encoding"] = "windows-1252"
    }
    return $info
}

function Write-ToolFile([string]$path, [string]$text, $info, [int]$backupKeep = 5) {
    if (-not (& $script:ShouldWrite $path)) { return "whatif" }

    if ($info -and $info.Exists -and $info.Text -ceq $text) { return "unchanged" }

    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($info -and $info.Exists) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        Copy-Item -LiteralPath $path -Destination "$path.$stamp.bak" -Force -ErrorAction SilentlyContinue
        $leaf = Split-Path -Leaf $path
        Get-ChildItem -LiteralPath $parent -Filter "$leaf.*.bak" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip $backupKeep |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $enc = if ($info -and -not $info.IsUtf8) {
        [System.Text.Encoding]::GetEncoding(1252)
    } else {
        New-Object System.Text.UTF8Encoding($false)
    }
    [System.IO.File]::WriteAllText($path, $text, $enc)
    return "written"
}

function Get-Backups([string]$path) {
    $dir = Split-Path -Parent $path
    $leaf = Split-Path -Leaf $path
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.*.bak" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
}

# --- JSON ------------------------------------------------------------------

function ConvertTo-JsonText($value, [int]$indent = 0) {
    $pad = " " * $indent
    $padInner = " " * ($indent + 2)

    if ($null -eq $value) { return "null" }
    if ($value -is [bool]) { return $(if ($value) { "true" } else { "false" }) }

    # Every numeric type is enumerated rather than the common four. The old
    # version fell through to the object branch for [single] and [byte], which
    # serialised them as `{}` - silently, and with no way to tell.
    if ($value -is [byte]   -or $value -is [sbyte]  -or $value -is [int16] -or
        $value -is [uint16] -or $value -is [int]    -or $value -is [uint32] -or
        $value -is [int64]  -or $value -is [uint64] -or $value -is [bigint]) {
        return [string]$value
    }
    if ($value -is [single] -or $value -is [double] -or $value -is [decimal]) {
        # Round-trippable, and not locale-dependent: JSON requires a dot, and
        # (0.5).ToString() is "0,5" on a machine with a comma decimal separator.
        return ([double]$value).ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($value -is [char])  { return (ConvertTo-JsonString ([string]$value)) }
    if ($value -is [string]) { return (ConvertTo-JsonString $value) }
    if ($value -is [datetime]) {
        return (ConvertTo-JsonString $value.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture))
    }

    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Count -eq 0) { return "{}" }
        $parts = @()
        foreach ($k in $value.Keys) {
            $parts += "$padInner$(ConvertTo-JsonString ([string]$k)): $(ConvertTo-JsonText $value[$k] ($indent + 2))"
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }

    # [string] is IEnumerable and [char] is too, so both are handled above.
    # Anything genuinely enumerable left is a list.
    if ($value -is [System.Collections.IEnumerable]) {
        $arr = @($value)
        if ($arr.Count -eq 0) { return "[]" }
        $parts = @()
        foreach ($item in $arr) { $parts += "$padInner$(ConvertTo-JsonText $item ($indent + 2))" }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }

    # Filter by member type, not by name. The old filter dropped every property
    # whose name started with "PS" to hide PowerShell's adapter properties, which
    # also threw away legitimate keys - and opencode model ids come straight from
    # 9Router, so a model called "PS-something" would vanish from the config.
    $props = @($value.PSObject.Properties | Where-Object {
        $_.MemberType -eq "NoteProperty" -or $_.MemberType -eq "Property" -or
        $_.MemberType -eq "AliasProperty" -or $_.MemberType -eq "ScriptProperty"
    })
    if ($props.Count -eq 0) { return "{}" }
    $parts = @()
    foreach ($p in $props) {
        $parts += "$padInner$(ConvertTo-JsonString $p.Name): $(ConvertTo-JsonText $p.Value ($indent + 2))"
    }
    return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); continue }
            '\'  { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ([int]$ch -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonOrNull([string]$text) {
    if ($null -eq $text) { return $null }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}