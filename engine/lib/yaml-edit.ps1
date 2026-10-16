<#
    yaml-edit.ps1 - indentation-aware YAML block editing.

    Design rule: every operation is scoped to one block and returns a NEW line
    array. Nothing ever holds an index across a mutation.

    The previous implementation did this instead:

        $nb = Find-YamlBlock $lines "9router" 2
        ... $lines = Set-YamlValue ...        # array changes length
        $mm = Find-YamlBlock $lines "models" 4 $nb.Start $nb.End
        ... $lines = @($lines[0..($nb.End - 1)]) + $gen + @($lines[$nb.End..($lines.Count - 1)])

    Two failure modes fell straight out of that shape:

      - Find-YamlBlock with no bounds returns the FIRST match in the file, so
        `models` under providers.other was rewritten instead of providers.9router,
        and the real 9router block was left untouched. Reported as "updated".
      - $nb.End is stale after any edit, and $lines[N..(N-1)] is a descending
        range that PowerShell resolves to the last element rather than an empty
        set, so the final line got duplicated into the file.

    Here, Splice-Lines is the only place lines move, and it guards each slice.
#>

function Get-LineIndent([string]$line) {
    return $line.Length - $line.TrimStart(" ").Length
}

function Get-LineContent([string]$line) {
    return $line.TrimEnd()
}

# Removes a run of $Count lines at $Start and splices $Replacement in.
# Every slice is range-checked, so start=0, start=Count and count=0 are all
# ordinary cases rather than the traps they were.
function Splice-Lines([string[]]$Lines, [int]$Start, [int]$Count, [string[]]$Replacement) {
    $head = @()
    if ($Start -gt 0) { $head = @($Lines[0..($Start - 1)]) }
    $tail = @()
    $tailStart = $Start + $Count
    if ($tailStart -lt $Lines.Count) { $tail = @($Lines[$tailStart..($Lines.Count - 1)]) }
    return [string[]]@($head + @($Replacement) + @($tail))
}

# Locates `Key:` at $Indent between $From and $To (exclusive).
#
# Returns @{ Start; End; ContentStart; ContentEnd } where End is the index of
# the first following line at the same or shallower indent, i.e. the exclusive
# end of the whole block including its children. Blank lines and comments are
# skipped while scanning, so a trailing comment does not truncate a block.
function Find-YamlBlock([string[]]$Lines, [string]$Key, [int]$Indent, [int]$From = 0, [int]$To = -1) {
    $pat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    $limit = if ($To -ge 0) { [Math]::Min($To, $Lines.Count) } else { $Lines.Count }

    for ($i = $From; $i -lt $limit; $i++) {
        if ($Lines[$i] -notmatch $pat) { continue }
        $end = $Lines.Count
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            $t = $Lines[$j].Trim()
            if ($t -eq "" -or $t.StartsWith("#")) { continue }
            if ((Get-LineIndent $Lines[$j]) -le $Indent) { $end = $j; break }
        }
        return @{ Start = $i; End = $end; ContentStart = $i + 1; ContentEnd = $end }
    }
    return $null
}

# Resolves a nested path, e.g. @("providers", "9router"). Returns the innermost
# block. Absent at any level gives $null rather than an index of 0.
function Find-YamlPath([string[]]$Lines, [string[]]$Path) {
    $from = 0; $to = $Lines.Count; $indent = 0; $found = $null
    foreach ($key in $Path) {
        $found = Find-YamlBlock $Lines $key $indent $from $to
        if (-not $found) { return $null }
        $from = $found.ContentStart
        $to = $found.End
        $indent = $indent + 2
    }
    return $found
}

function Test-YamlKey([string[]]$Lines, $Block, [string]$Key, [int]$Indent) {
    $pat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        if ($Lines[$i] -match $pat) { return $true }
    }
    return $false
}

function Get-YamlScalar([string[]]$Lines, $Block, [string]$Key, [int]$Indent) {
    if (-not $Block) { return $null }
    $pat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:\s*(.*)$"
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        if ($Lines[$i] -match $pat) {
            $v = $Matches[1].Trim()
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                $v = $v.Substring(1, $v.Length - 2)
            } elseif ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    }
    return $null
}

# Quotes a scalar when leaving it bare would change its meaning or break the
# parse. Model ids arrive from 9Router unfiltered, and '#' in particular starts
# a YAML comment, which silently truncates the value.
#
# -Raw writes the value as given, for the keys that must stay booleans or
# numbers (discover_models, max_turns). Quoting those turns a working boolean
# into the string "false", which is a different thing to every YAML reader.
function Format-YamlScalar([string]$v, [switch]$Raw) {
    if ($Raw) { return $v }
    if ($null -eq $v) { return '""' }
    if ($v -eq "") { return '""' }

    $needsQuote = $false
    if ($v -ne $v.Trim()) { $needsQuote = $true }
    if ($v -match '^[#\-?:,\[\]{}&*!|>%@`"'']') { $needsQuote = $true }
    if ($v -match ':\s') { $needsQuote = $true }
    if ($v -match '\s#') { $needsQuote = $true }
    if ($v -match '^(true|false|null|yes|no|on|off)$') { $needsQuote = $true }
    if ($v -match '^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$') { $needsQuote = $true }

    if (-not $needsQuote) { return $v }
    return '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"'
}

# Sets Key inside Block. Replaces when present, appends otherwise. Returns the
# new array only - the caller must re-find the block, because the length may
# have changed.
# A map key can need quoting for the same reasons a value can. Hermes writes the
# model list as `models:` -> `<id>: {}`, so an id containing a space or a
# comment-starting # becomes the key rather than the value.
function Format-YamlKey([string]$k) {
    if ($null -eq $k -or $k -eq "") { return '""' }
    $plain = $k -notmatch '[:#\[\]{}&*!|>%@`"''?,-]'
    $plain = $plain -and ($k -notmatch '\s')
    if ($plain) {
        return $(if ($k -match '^(true|false|null|yes|no|on|off)$') { '"' + $k + '"' } elseif ($k -match '^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$') { '"' + $k + '"' } else { $k })
    }
    return '"' + ($k -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Set-YamlScalar([string[]]$Lines, $Block, [string]$Key, [string]$Value, [int]$Indent, [switch]$Raw) {
    if (-not $Block) { return $Lines }
    $pat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    $newLine = (" " * $Indent) + (Format-YamlKey $Key) + ": " + (Format-YamlScalar $Value -Raw:$Raw)
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        if ($Lines[$i] -match $pat) {
            $copy = [string[]]$Lines.Clone()
            $copy[$i] = $newLine
            return $copy
        }
    }
    # Append at the end of the block's content, so a trailing comment that
    # belongs to the parent block stays at the parent level.
    return Splice-Lines $Lines $Block.End 0 @($newLine)
}

function Remove-YamlKey([string[]]$Lines, $Block, [string]$Key, [int]$Indent) {
    if (-not $Block) { return $Lines }
    $pat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -gt $Block.ContentStart - 1 -and $i -lt $Block.End -and $Lines[$i] -match $pat) { continue }
        [void]$keep.Add($Lines[$i])
    }
    return [string[]]$keep.ToArray()
}

# Replaces a block's body, keeping the `key:` line itself. $Body must NOT repeat
# the key line - doing so is how a file ends up with two consecutive `models:`
# lines, where the second one is an empty map and swallows the real entries.
function Set-YamlBlockBody([string[]]$Lines, $Block, [string[]]$Body, [int]$Indent) {
    if (-not $Block) { return $Lines }
    return Splice-Lines $Lines $Block.ContentStart ($Block.End - $Block.ContentStart) $Body
}

# Replaces the whole block, header line included. $Replacement is the complete
# new block, so it does start with the `key:` line at $Indent.
function Replace-YamlBlock([string[]]$Lines, $Block, [string[]]$Replacement, [int]$Indent) {
    if (-not $Block) { return $Lines }
    return Splice-Lines $Lines $Block.Start ($Block.End - $Block.Start) $Replacement
}

# Creates a nested block if it is absent, and returns the lines with the block
# present. `$NewBody` is the child lines, already indented.
function Ensure-YamlBlock([string[]]$Lines, [string]$Key, [int]$Indent, [string[]]$NewBody) {
    $existing = Find-YamlBlock $Lines $Key $Indent
    if ($existing) {
        return Set-YamlBlockBody $Lines $existing $NewBody ($Indent + 2)
    }
    $block = @(((" " * $Indent) + $Key + ":"))
    if ($NewBody.Count -gt 0) { $block += $NewBody }
    return Splice-Lines $Lines $Lines.Count 0 $block
}

# Collects the child keys of a block, in file order, at the given indent.
function Get-YamlKeys([string[]]$Lines, $Block, [int]$Indent) {
    $out = @()
    if (-not $Block) { return $out }
    $pat = "^" + (" " * $Indent) + "([^\s:#][^:]*)\s*:"
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        $t = $Lines[$i].Trim()
        if (-not $t -or $t.StartsWith("#") -or $t.StartsWith("- ")) { continue }
        if ((Get-LineIndent $Lines[$i]) -ne $Indent) { continue }
        if ($Lines[$i] -match $pat) { $out += $Matches[1].Trim() }
    }
    return $out
}

# Sequence item values under `key:` within a block. Model lists are emitted
# this way in both omp's models.yml and Hermes' config.yaml.
function Get-YamlSeqValues([string[]]$Lines, $Block, [string]$Key, [int]$Indent) {
    $out = @()
    if (-not $Block) { return $out }
    $keyPat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    $itemPat = "^" + (" " * ($Indent + 2)) + "-\s*(.+?)\s*$"
    $inSeq = $false
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        if (-not $inSeq) {
            if ($Lines[$i] -match $keyPat) { $inSeq = $true }
            continue
        }
        $t = $Lines[$i].Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ((Get-LineIndent $Lines[$i]) -le $Indent) { break }
        if ($Lines[$i] -match $itemPat) {
            $v = $Matches[1].Trim()
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
            $out += $v
        }
    }
    return $out
}

# `models:` written as a map of `id: {}` rather than a list.
function Get-YamlMapKeys([string[]]$Lines, $Block, [string]$Key, [int]$Indent) {
    $out = @()
    if (-not $Block) { return $out }
    $keyPat = "^" + (" " * $Indent) + [regex]::Escape($Key) + "\s*:"
    $inSeq = $false
    for ($i = $Block.ContentStart; $i -lt $Block.End; $i++) {
        if (-not $inSeq) {
            if ($Lines[$i] -match $keyPat) { $inSeq = $true }
            continue
        }
        $t = $Lines[$i].Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ((Get-LineIndent $Lines[$i]) -le $Indent) { break }
        # Quoted keys first: an id containing a colon may be written quoted.
        if ($t -match '^"((?:[^"\\]|\\.)*)"\s*:') {
            $out += ($Matches[1] -replace '\\(.)', '$1')
        } elseif ($t -match "^'([^']*)'\s*:") {
            $out += $Matches[1]
        } elseif ($t -match '^(.+):\s*\{\s*\}\s*(#.*)?$') {
            # Unquoted, but the id itself contains a colon
            # (xkiro/qwen/qwen3.8-max:free: {}). The key runs to the LAST
            # colon; splitting at the first one truncated the id, so every
            # sync reported a phantom removal plus an add of the same model.
            $out += $Matches[1].Trim()
        } elseif ($t -match '^([^:#]+):') {
            $out += $Matches[1].Trim().Trim([char[]]@("'", '"'))
        }
    }
    return $out
}

# Splits into lines with LF endings and no trailing empty entry, so every index
# arithmetic in this file is against real content.
function ConvertTo-YamlLines([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return [string[]]@() }
    $t = $text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    while ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t -eq "") { return [string[]]@() }
    return [string[]]($t -split "`n")
}