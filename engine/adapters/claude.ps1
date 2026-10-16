<#
    claude.ps1 - ~/.claude/settings.json

    Merge only. Claude Code creates this file on first run; writing one on a PC
    that has never run Claude would leave a settings.json nothing reads.
#>

function Get-ClaudePath { return (Join-Path $env:USERPROFILE ".claude\settings.json") }

function Write-ClaudeConfig {
    $tool = "claude"
    $path = Get-ClaudePath

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "claude -> .claude\settings.json is missing, skipped."
        Write-Warn "          run claude once so it writes the config, then sync again."
        Add-Report $tool $path "not-installed" "claude has never been run on this PC (no settings.json)"
        return
    }

    $info = Read-ToolFile $path
    $cfg = ConvertTo-JsonOrNull $info.Text

    $out = [ordered]@{}
    if ($cfg) { foreach ($p in $cfg.PSObject.Properties) { $out[$p.Name] = $p.Value } }
    $out["hasCompletedOnboarding"] = $true

    $envObj = $null
    if ($out.Contains("env") -and $out["env"]) { $envObj = $out["env"] }
    if (-not $envObj) { $envObj = [ordered]@{} }
    if ($envObj -is [System.Collections.IDictionary]) {
        $envObj["ANTHROPIC_BASE_URL"] = $script:ApiBase
        $envObj["ANTHROPIC_AUTH_TOKEN"] = $script:ApiKey
    } else {
        $envObj | Add-Member -MemberType NoteProperty -Name "ANTHROPIC_BASE_URL" -Value $script:ApiBase -Force
        $envObj | Add-Member -MemberType NoteProperty -Name "ANTHROPIC_AUTH_TOKEN" -Value $script:ApiKey -Force
    }
    $out["env"] = $envObj

    # Reported with a model count even though no model list is written here, so
    # the state file no longer records modelCount: 0 for a tool that is working.
    Add-Change $tool $path @() @($script:Models | ForEach-Object { $_.id })
    $res = Write-ToolFile $path ((ConvertTo-JsonText $out) + "`n") $info $script:BackupKeep
    Add-Report $tool $path (ConvertTo-WriteStatus $res) "ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN"
}