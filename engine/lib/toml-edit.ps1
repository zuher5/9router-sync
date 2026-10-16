<#
    toml-edit.ps1 - section-aware TOML editing, for Codex.

    The previous Set-TomlValue searched the whole file for `key =` and took the
    first hit, which is wrong for TOML in a way it is not wrong for JSON or YAML:
    a key name is only meaningful inside its section. Against a real
    ~/.codex/config.toml it overwrote base_url inside [model_providers.other]
    and appended api_key into that same foreign section - so the file was both
    corrupted and non-functional, while the run reported "updated".
#>

# Returns @{ Section; BodyStart; BodyEnd; HasSection } for `key = value`.
# $Section is "" for the top-level table that precedes the first [header].
function Find-TomlKey([string[]]$Lines, [string]$Key, [string]$Section = "") {
    $pat = "^" + [regex]::Escape($Key) + "\s*="
    $current = ""
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t.StartsWith("#")) { continue }
        if ($t -match '^\[([^\]]+)\]') { $current = $Matches[1].Trim(); continue }
        if ($current -ne $Section) { continue }
        if ($Lines[$i] -match $pat) {
            return @{ Line = $i; Section = $current }
        }
    }
    return $null
}

# Index just past the last line belonging to $Section.
function Get-TomlSectionEnd([string[]]$Lines, [string]$Section) {
    $current = ""
    $insertAt = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t.StartsWith("#")) { continue }
        if ($t -match '^\[([^\]]+)\]') { $current = $Matches[1].Trim() }
        if ($current -eq $Section) { $insertAt = $i + 1 }
    }
    return $insertAt
}

function Test-TomlSection([string[]]$Lines, [string]$Section) {
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if ($t.StartsWith("#")) { continue }
        if ($t -match '^\[' + [regex]::Escape($Section) + '\]\s*$') { return $true }
    }
    return $false
}

# Replaces the key in place when it exists. Otherwise inserts it into $Section,
# creating the section header first if needed - so a key always lands where it
# will actually be read from, never at end-of-file inside whatever section
# happens to be last.
function Set-TomlKey([string[]]$Lines, [string]$Key, [string]$Value, [string]$Section = "") {
    $line = "$Key = `"$Value`""
    $found = Find-TomlKey $Lines $Key $Section
    if ($found) {
        $copy = [string[]]$Lines.Clone()
        $copy[$found.Line] = $line
        return $copy
    }

    # The top-level table has no header, so there is nothing to create for it.
    # Emitting "[]" would be a table header for the empty name.
    if ($Section -ne "" -and -not (Test-TomlSection $Lines $Section)) {
        if ($Lines.Count -gt 0) { $Lines = @($Lines + @("", "[$Section]")) }
        else { $Lines = @("[$Section]") }
    }
    $at = Get-TomlSectionEnd $Lines $Section
    return Splice-Lines $Lines $at 0 @($line)
}

function Get-TomlKey([string[]]$Lines, [string]$Key, [string]$Section = "") {
    $found = Find-TomlKey $Lines $Key $Section
    if (-not $found) { return $null }
    $v = ($Lines[$found.Line] -split "=", 2)[1].Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
    return $v
}

# Lists section names in file order, which is what the UI shows so a user can
# see what else Codex is configured against.
function Get-TomlSections([string[]]$Lines) {
    $out = @()
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if ($t.StartsWith("#")) { continue }
        if ($t -match '^\[([^\]]+)\]') { $out += $Matches[1].Trim() }
    }
    return $out
}

# Minimal, strict-enough parse to prove a file is not corrupt. Used by the
# validator only; the writers never need it.
function Test-TomlParses([string]$text) {
    $lines = ConvertTo-YamlLines $text
    $table = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t = $raw.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ($t -match '^\[([^\]]+)\]$') { $table = $Matches[1].Trim(); continue }
        if ($t.StartsWith("[")) { throw "line $($i + 1): unterminated table header" }
        if ($t -match '^[A-Za-z0-9_\-"]+\s*=') { continue }
        if ($t -match '^[A-Za-z0-9_\-"'']+\s*=.*$') { continue }
        throw "line $($i + 1): not a key/value pair: $t"
    }
}