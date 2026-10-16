<#
    opencode.ps1 - ~/.config/opencode/opencode.json

    Merged, never replaced. mcp, agents and every other provider survive.
    9Router emits the v1 provider shape; OpenCode v2 wants plural `providers`
    with package/settings and capabilities.
#>

function Get-OpenCodePaths {
    return @((Join-Path $env:USERPROFILE ".config\opencode\opencode.json"))
}

function Get-OpenCodeModelIds($cfg) {
    if (-not $cfg) { return [string[]]@() }
    $out = @()
    foreach ($key in @("providers", "provider")) {
        if (-not ($cfg.PSObject.Properties.Name -contains $key) -or -not $cfg.$key) { continue }
        $p = $cfg.$key
        if ($p.PSObject.Properties.Name -notcontains "9router") { continue }
        $nine = $p.'9router'
        if (-not $nine -or -not ($nine.PSObject.Properties.Name -contains "models")) { continue }
        $out += @($nine.models.PSObject.Properties.Name)
    }
    return [string[]]$out
}

function Write-OpenCodeConfig([string]$defaultId) {
    $tool = "opencode"
    $path = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "opencode -> opencode.json is missing, skipped."
        Write-Warn "            run opencode once so it writes the config, then sync again."
        Add-Report $tool $path "not-installed" "opencode has never been run on this PC (no opencode.json)"
        return
    }

    $info = Read-ToolFile $path
    $cfg = ConvertTo-JsonOrNull $info.Text
    $before = @(Get-OpenCodeModelIds $cfg)
    $validIds = @($script:Models | ForEach-Object { $_.id })
    # Pins arrive as bare model names while resolved ids can still carry the
    # 9router/ prefix (mirrored-as-is entries do). Comparing raw forms
    # unpinned agents whose model was right there in the written list.
    $strippedValid = @($validIds | ForEach-Object { "$_" -replace '^9router/', '' })

    $existingProviders = $null
    if ($cfg) {
        if ($cfg.PSObject.Properties.Name -contains "providers" -and $cfg.providers) { $existingProviders = $cfg.providers }
        elseif ($cfg.PSObject.Properties.Name -contains "provider" -and $cfg.provider) { $existingProviders = $cfg.provider }
    }

    # Keep whichever adapter package the file already used. Hardcoding it here
    # would silently swap a user's working provider for a different one.
    $pkg = "aisdk:@ai-sdk/openai-compatible"
    if ($existingProviders -and ($existingProviders.PSObject.Properties.Name -contains "9router")) {
        $nine = $existingProviders.'9router'
        foreach ($k in @("package", "npm")) {
            if (($nine.PSObject.Properties.Name -contains $k) -and $nine.$k) { $pkg = "$($nine.$k)"; break }
        }
    }

    $providers = [ordered]@{}
    if ($existingProviders) {
        foreach ($p in $existingProviders.PSObject.Properties) {
            if ($p.Name -ne "9router") { $providers[$p.Name] = $p.Value }
        }
    }

    $modelObj = [ordered]@{}
    foreach ($m in $script:Models) {
        $caps = [ordered]@{ tools = [bool]$m.tools; input = @("text"); output = @("text") }
        if ($m.vision) { $caps["input"] = @("text", "image") }
        $modelObj[$m.id] = [ordered]@{ name = $m.id; capabilities = $caps }
    }
    $providers["9router"] = [ordered]@{
        package  = $pkg
        settings = [ordered]@{ baseURL = $script:ApiBase; apiKey = $script:ApiKey }
        models   = $modelObj
    }

    # An agent pinned to a model that no longer exists gets unpinned, not deleted:
    # the agent keeps its own description, mode and tools and falls back to the
    # top-level default.
    $agentsOut = $null
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains "agents") -and $cfg.agents) {
        $agentsOut = [ordered]@{}
        foreach ($ap in $cfg.agents.PSObject.Properties) {
            $entry = $ap.Value
            $pin = $null
            if ($entry -and ($entry.PSObject.Properties.Name -contains "model")) { $pin = Get-ModelPin $entry.model }
            if ($pin -and $pin.Provider -eq "9router" -and ($strippedValid -notcontains ($pin.Model -replace '^9router/', ''))) {
                $newEntry = [ordered]@{}
                foreach ($ep in $entry.PSObject.Properties) {
                    if ($ep.Name -ne "model") { $newEntry[$ep.Name] = $ep.Value }
                }
                $agentsOut[$ap.Name] = $newEntry
                Add-Dangling $tool "agents.$($ap.Name).model" $pin.Model
                Write-Warn "opencode -> agents.$($ap.Name) was pinned to '$($pin.Model)', released: the model is gone."
            } else {
                $agentsOut[$ap.Name] = $entry
            }
        }
    }

    $out = [ordered]@{}
    $sawProviderKey = $false
    if ($cfg) {
        foreach ($p in $cfg.PSObject.Properties) {
            switch ($p.Name) {
                "model"     { $out["model"] = "9router/$defaultId" }
                "provider"  { $out["providers"] = $providers; $sawProviderKey = $true }
                "providers" { $out["providers"] = $providers; $sawProviderKey = $true }
                "agents"    { if ($agentsOut) { $out["agents"] = $agentsOut } else { $out["agents"] = $p.Value } }
                default     { $out[$p.Name] = $p.Value }
            }
        }
    }
    if (-not $out.Contains("model")) { $out["model"] = "9router/$defaultId" }
    if (-not $sawProviderKey) { $out["providers"] = $providers }
    if (-not $out.Contains('$schema')) { $out['$schema'] = "https://opencode.ai/config.json" }

    Add-Change $tool $path $before $validIds
    $res = Write-ToolFile $path ((ConvertTo-JsonText $out) + "`n") $info $script:BackupKeep
    Add-Report $tool $path (ConvertTo-WriteStatus $res) "$($script:Models.Count) models, default 9router/$defaultId"
}