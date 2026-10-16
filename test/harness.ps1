<#
    harness.ps1 - assertions, plus the engine loaded in a state the tests can
    poke at. No dependencies; run via run-tests.ps1.
#>

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

$engineRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "engine"

# Loaded with -WhatIf semantics neutral: the adapters never run during unit
# tests, but the shared ShouldWrite hook has to exist.
$script:ShouldWrite = { param([string]$path) return $false }
$script:Quiet = $true

. "$engineRoot\lib\core.ps1"
. "$engineRoot\lib\bridge.ps1"
. "$engineRoot\lib\yaml-edit.ps1"
. "$engineRoot\lib\toml-edit.ps1"
. "$engineRoot\lib\resolve.ps1"
. "$engineRoot\lib\config.ps1"
. "$engineRoot\adapters\opencode.ps1"
. "$engineRoot\adapters\pi.ps1"
. "$engineRoot\adapters\omp.ps1"
. "$engineRoot\adapters\hermes.ps1"
. "$engineRoot\adapters\claude.ps1"
. "$engineRoot\adapters\codex.ps1"

$script:TestRoot = Split-Path -Parent $PSScriptRoot

function Test-Case([string]$name, [scriptblock]$body) {
    try {
        & $body
        $script:Passed++
        Write-Host "  ok   $name" -ForegroundColor DarkGray
    } catch {
        $script:Failed++
        $script:Failures += $name
        Write-Host "  FAIL $name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal($actual, $expected, [string]$because = "") {
    $a = if ($null -eq $actual) { "<null>" } else { "$actual" }
    $e = if ($null -eq $expected) { "<null>" } else { "$expected" }
    if ($a -cne $e) { throw "expected '$e' but got '$a'$(if ($because) { " ($because)" })" }
}

function Assert-True($value, [string]$because = "") {
    if (-not $value) { throw "expected true but got '$value'$(if ($because) { " ($because)" })" }
}

function Assert-Contains([string]$haystack, [string]$needle, [string]$because = "") {
    if ($null -eq $haystack -or $haystack.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "expected to contain '$needle'$(if ($because) { " ($because)" })`n--- actual ---`n$haystack"
    }
}

function Assert-NotContains([string]$haystack, [string]$needle, [string]$because = "") {
    if ($null -ne $haystack -and $haystack.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) {
        throw "expected NOT to contain '$needle'$(if ($because) { " ($because)" })`n--- actual ---`n$haystack"
    }
}

# Writes a throwaway file and returns its path, for round-trip tests.
function New-TempFile([string]$name, [string]$content) {
    $dir = Join-Path $env:TEMP ("9sync-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir $name
    [System.IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

function Remove-TempDir([string]$filePath) {
    $dir = Split-Path -Parent $filePath
    if ($dir -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}