<#
    run-tests.ps1 - the unit and adapter suites. No Pester, no install.

    The end-to-end file is separate because it needs a mock bridge running and
    is named e2e.ps1, so it is not picked up here.

    .\test\run-tests.ps1              run everything in this file set
    .\test\run-tests.ps1 -Name yaml   run one file
#>

param([string]$Name = "")

$ErrorActionPreference = "Stop"
$testDir = $PSScriptRoot

. "$testDir\harness.ps1"

$files = @(Get-ChildItem -LiteralPath $testDir -Filter "*.tests.ps1" | Sort-Object Name)
if ($Name) { $files = @($files | Where-Object { $_.BaseName -like "*$Name*" }) }
if ($files.Count -eq 0) { Write-Host "no test files matched '$Name'" -ForegroundColor Yellow; exit 1 }

foreach ($f in $files) {
    Write-Host ""
    Write-Host "== $($f.Name)" -ForegroundColor Cyan
    . $f.FullName
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failed) failed, $($script:Passed) passed" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  FAIL $($f.Name)" -ForegroundColor Red }
    exit 1
}
Write-Host "$($script:Passed) passed" -ForegroundColor Green
exit 0