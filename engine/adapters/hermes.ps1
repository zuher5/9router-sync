<#
    hermes.ps1 - %LOCALAPPDATA%\hermes\config.yaml + .env

    `hermes config path` points at LOCALAPPDATA, not ~/.hermes. The file has
    around thirty top-level sections and other providers, so only the 9router
    blocks are touched. If providers.9router is absent the block is created
    rather than reported skipped: a provider block is the thing this tool owns,
    and a config without one is simply not set up yet.
#>

# $env:LOCALAPPDATA, not [Environment]::GetFolderPath(): the latter reads the
# user's real folder from the registry and ignores the variable, so any test or
# sandbox that sets the variable would still write to the live config.
function Get-HermesBaseDir {
    $root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath("LocalApplicationData") }
    return (Join-Path $root "hermes")
}

function Get-HermesPaths {
    $b = Get-HermesBaseDir
    return @((Join-Path $b "config.yaml"), (Join-Path $b ".env"))
}

# fallback_providers reach 9Router through base_url directly, bypassing the
# model list, so they can still work. Listed for awareness, never rewritten.
function Get-HermesFallbackRefs([string[]]$lines, [string]$hostPattern) {
    $fb = Find-YamlBlock $lines "fallback_providers" 0
    if (-not $fb) { return @() }
    $out = @(); $cur = $null
    for ($i = $fb.ContentStart; $i -lt $fb.End; $i++) {
        $l = $lines[$i]; $t = $l.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ((Get-LineIndent $l) -le 2) {
            if ($cur -and $cur.BaseUrl -like "*$hostPattern*") { $out += $cur }
            $cur = [pscustomobject]@{ Model = ""; BaseUrl = ""; Provider = "" }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*model:\s*(.+?)\s*$')        { $cur.Model    = $Matches[1].Trim().Trim([char[]]@("'", '"')) }
        elseif ($l -match '^\s*base_url:\s*(.+?)\s*$') { $cur.BaseUrl  = $Matches[1].Trim().Trim([char[]]@("'", '"')) }
        elseif ($l -match '^\s*provider:\s*(.+?)\s*$') { $cur.Provider = $Matches[1].Trim().Trim([char[]]@("'", '"')) }
    }
    if ($cur -and $cur.BaseUrl -like "*$hostPattern*") { $out += $cur }
    return $out
}

function Get-HermesModelIds([string[]]$lines) {
    foreach ($cand in @("9router", "9router-cloud")) {
        $provBlock = Find-YamlBlock $lines $cand 2
        if (-not $provBlock) { continue }
        return [string[]]@(Get-YamlMapKeys $lines $provBlock "models" 4)
    }
    return [string[]]@()
}

function Write-HermesConfig([string]$defaultId) {
    $tool = "hermes"
    $base = Get-HermesBaseDir
    $cfgPath = Join-Path $base "config.yaml"
    $envPath = Join-Path $base ".env"
    $validIds = @($script:Models | ForEach-Object { $_.id })

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Warn "hermes -> not installed on this PC, skipped."
        Write-Warn "         no config.yaml at $cfgPath"
        Write-Warn "         install Hermes first, or drop 'hermes' from tools in Settings."
        Add-Report $tool $cfgPath "not-installed" "hermes is not installed on this PC (no config.yaml)"
        return
    }

    $info = Read-ToolFile $cfgPath
    $lines = ConvertTo-YamlLines $info.Text
    $before = @(Get-HermesModelIds $lines)

    $apiHost = ([Uri]$script:ApiBase).Host
    foreach ($f in (Get-HermesFallbackRefs $lines $apiHost)) {
        Add-Report $tool $cfgPath "unchanged" "$($f.Model) reaches 9Router directly via base_url, left untouched"
    }

    # Reuse an existing 9router provider under whichever name is already there,
    # so an older install keeps working after the name changed.
    $provName = "9router"
    $providersBlock = Find-YamlBlock $lines "providers" 0
    if ($providersBlock) {
        foreach ($cand in @("9router-cloud", "9router")) {
            if (Find-YamlBlock $lines $cand 2 $providersBlock.ContentStart $providersBlock.End) { $provName = $cand; break }
        }
    }

    # --- model: block -----------------------------------------------------
    $mb = Find-YamlBlock $lines "model" 0
    if ($mb) {
        $lines = Set-YamlScalar $lines $mb "default" $defaultId 2
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "provider" $provName 2
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "base_url" $script:ApiBase 2
        $mb = Find-YamlBlock $lines "model" 0
        # key_env names the variable in .env; api_key is the alternative form.
        # Whichever the file already uses is what gets pointed at the new key,
        # rather than adding a second one the tool ignores.
        if (Test-YamlKey $lines $mb "key_env" 2) {
            $lines = Set-YamlScalar $lines $mb "key_env" "OPENAI_API_KEY" 2
        } elseif (Test-YamlKey $lines $mb "api_key" 2) {
            $mb = Find-YamlBlock $lines "model" 0
            $lines = Set-YamlScalar $lines $mb "api_key" '${OPENAI_API_KEY}' 2
        } else {
            $mb = Find-YamlBlock $lines "model" 0
            $lines = Set-YamlScalar $lines $mb "key_env" "OPENAI_API_KEY" 2
        }
    } else {
        $lines = Splice-Lines $lines 0 0 @(
            "model:"
            "  default: $(Format-YamlScalar $defaultId)"
            "  provider: $(Format-YamlScalar $provName)"
            "  base_url: $(Format-YamlScalar $script:ApiBase)"
            "  key_env: OPENAI_API_KEY"
        )
    }

    # --- providers.<name> block -------------------------------------------
    $providersBlock = Find-YamlBlock $lines "providers" 0
    $pb = if ($providersBlock) { Find-YamlBlock $lines $provName 2 $providersBlock.ContentStart $providersBlock.End } else { $null }

    if ($pb) {
        foreach ($pair in @(
            @{ k = "name";            v = $provName;      raw = $false },
            @{ k = "base_url";        v = $script:ApiBase; raw = $false },
            @{ k = "key_env";         v = "OPENAI_API_KEY"; raw = $false },
            @{ k = "model";           v = $defaultId;     raw = $false },
            @{ k = "default_model";   v = $defaultId;     raw = $false },
            # Raw: a quoted "false" is a string, and Hermes reads this as a flag.
            @{ k = "discover_models"; v = "false";        raw = $true }
        )) {
            $pb = Find-YamlBlock $lines $provName 2
            if ($pair.raw) { $lines = Set-YamlScalar $lines $pb $pair.k $pair.v 4 -Raw }
            else { $lines = Set-YamlScalar $lines $pb $pair.k $pair.v 4 }
        }

        # $body is the complete block, header included, so it replaces the whole
        # existing block rather than being appended to the one already there.
        $pb = Find-YamlBlock $lines $provName 2
        $body = @("    models:")
        foreach ($m in $script:Models) { $body += "      $(Format-YamlScalar $m.id): {}" }
        $mm = Find-YamlBlock $lines "models" 4 $pb.ContentStart $pb.End
        if ($mm) { $lines = Replace-YamlBlock $lines $mm $body 4 }
        else { $lines = Splice-Lines $lines $pb.End 0 $body }
    } else {
        $newProv = @(
            "  $(Format-YamlScalar $provName):"
            "    name: $provName"
            "    base_url: $(Format-YamlScalar $script:ApiBase)"
            "    key_env: OPENAI_API_KEY"
            "    model: $(Format-YamlScalar $defaultId)"
            "    default_model: $(Format-YamlScalar $defaultId)"
            "    discover_models: false"
            "    models:"
        )
        foreach ($m in $script:Models) { $newProv += "      $(Format-YamlScalar $m.id): {}" }

        $providersBlock = Find-YamlBlock $lines "providers" 0
        if ($providersBlock) {
            # Appended at the end of the providers block, so providers written
            # after it keep their position and no unrelated section is entered.
            $lines = Splice-Lines $lines $providersBlock.End 0 $newProv
        } else {
            $lines = Splice-Lines $lines $lines.Count 0 (@("providers:") + $newProv)
        }
    }

    Add-Change $tool $cfgPath $before $validIds
    $res = Write-ToolFile $cfgPath ((@($lines) -join "`n") + "`n") $info $script:BackupKeep
    Add-Report $tool $cfgPath (ConvertTo-WriteStatus $res) "$($script:Models.Count) models, default $defaultId"

    # --- .env -------------------------------------------------------------
    $envInfo = Read-ToolFile $envPath
    $elines = ConvertTo-YamlLines $envInfo.Text
    $found = $false
    for ($i = 0; $i -lt $elines.Count; $i++) {
        if ($elines[$i] -match '^\s*OPENAI_API_KEY\s*=') {
            $elines[$i] = "OPENAI_API_KEY=$script:ApiKey"; $found = $true; break
        }
    }
    if (-not $found) { $elines = @($elines) + @("OPENAI_API_KEY=$script:ApiKey") }
    $res2 = Write-ToolFile $envPath ((@($elines) -join "`n") + "`n") $envInfo $script:BackupKeep
    Add-Report $tool $envPath (ConvertTo-WriteStatus $res2) "OPENAI_API_KEY"
}