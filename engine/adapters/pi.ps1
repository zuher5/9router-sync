<#
    pi.ps1 - ~/.pi/agent/models.json + settings.json

    Pi is installed by having its config directory, which it creates on first
    run. That is the presence test: checking for settings.json instead meant the
    dashboard called pi "not installed" while the sync went ahead and created
    both files.
#>

function Get-PiPaths {
    $dir = Join-Path $env:USERPROFILE ".pi\agent"
    return @((Join-Path $dir "models.json"), (Join-Path $dir "settings.json"))
}

function Get-PiAgentDir { return (Join-Path $env:USERPROFILE ".pi\agent") }

function Get-PiModelIds($cfg) {
    if (-not $cfg) { return [string[]]@() }
    $out = @()
    foreach ($key in @("providers", "provider")) {
        if (-not ($cfg.PSObject.Properties.Name -contains $key) -or -not $cfg.$key) { continue }
        $p = $cfg.$key
        if ($p.PSObject.Properties.Name -notcontains "9router") { continue }
        $nine = $p.'9router'
        if (-not $nine -or -not ($nine.PSObject.Properties.Name -contains "models")) { continue }
        foreach ($m in @($nine.models)) {
            if ($null -eq $m) { continue }
            if ($m -is [string]) { $out += $m; continue }
            if ($m.PSObject.Properties.Name -contains "id") { $out += "$($m.id)" }
        }
    }
    return [string[]]$out
}

function Write-PiConfig([string]$defaultId) {
    $tool = "pi"
    $agentDir = Get-PiAgentDir
    $modelsPath = Join-Path $agentDir "models.json"
    $settingsPath = Join-Path $agentDir "settings.json"
    $validIds = @($script:Models | ForEach-Object { $_.id })

    if (-not (Test-Path -LiteralPath $agentDir)) {
        Write-Warn "pi -> not installed on this PC, skipped."
        Write-Warn "       no config directory at $agentDir"
        Write-Warn "       install Pi first, or drop 'pi' from tools in Settings."
        Add-Report $tool $modelsPath "not-installed" "pi is not installed on this PC (no ~/.pi/agent directory)"
        return
    }

    # --- models.json ------------------------------------------------------
    $modelsInfo = Read-ToolFile $modelsPath
    $modelsCfg = ConvertTo-JsonOrNull $modelsInfo.Text
    $before = @(Get-PiModelIds $modelsCfg)

    $providers = [ordered]@{}
    if ($modelsCfg -and $modelsCfg.providers) {
        foreach ($p in $modelsCfg.providers.PSObject.Properties) {
            if ($p.Name -ne "9router") { $providers[$p.Name] = $p.Value }
        }
    }

    $modelList = @()
    foreach ($m in $script:Models) {
        $entry = [ordered]@{
            id            = $m.id
            name          = $m.id
            contextWindow = [int]$m.ctx
            maxTokens     = [int]$m.maxOut
        }
        if ($m.reasoning) { $entry["reasoning"] = $true }
        $entry["input"] = @(if ($m.vision) { "text", "image" } else { "text" })
        $modelList += $entry
    }

    $providers["9router"] = [ordered]@{
        baseUrl = $script:ApiBase
        apiKey  = $script:ApiKey
        api     = "openai-completions"
        models  = @($modelList)
    }

    $modelsOut = [ordered]@{}
    if ($modelsCfg) {
        foreach ($p in $modelsCfg.PSObject.Properties) {
            if ($p.Name -eq "providers") { $modelsOut["providers"] = $providers }
            else { $modelsOut[$p.Name] = $p.Value }
        }
    }
    if (-not $modelsOut.Contains("providers")) { $modelsOut["providers"] = $providers }

    Add-Change $tool $modelsPath $before $validIds
    $r1 = Write-ToolFile $modelsPath ((ConvertTo-JsonText $modelsOut) + "`n") $modelsInfo $script:BackupKeep
    Add-Report $tool $modelsPath (ConvertTo-WriteStatus $r1) "$($script:Models.Count) models in models.json"

    # --- settings.json ----------------------------------------------------
    $setInfo = Read-ToolFile $settingsPath
    $setCfg = ConvertTo-JsonOrNull $setInfo.Text
    $setOut = [ordered]@{}
    if ($setCfg) {
        foreach ($p in $setCfg.PSObject.Properties) {
            if ($p.Name -ne "defaultProvider" -and $p.Name -ne "defaultModel") {
                $setOut[$p.Name] = $p.Value
            }
        }
    }
    $setOut["defaultProvider"] = "9router"
    $setOut["defaultModel"] = $defaultId

    $r2 = Write-ToolFile $settingsPath ((ConvertTo-JsonText $setOut) + "`n") $setInfo $script:BackupKeep
    Add-Report $tool $settingsPath (ConvertTo-WriteStatus $r2) "defaultModel = $defaultId"
}