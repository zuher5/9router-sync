<#
    omp.ps1 - ~/.omp/agent/models.yml + config.yml

    Not installed on this PC, but kept working so it comes back the moment it is
    installed. Every lookup here is bounded to the providers.9router block; the
    previous version searched for the first `models:` at indent 4 in the file,
    which is whatever provider happened to be written first.
#>

function Get-OmpPaths {
    $dir = Join-Path $env:USERPROFILE ".omp\agent"
    return @((Join-Path $dir "models.yml"), (Join-Path $dir "config.yml"))
}

function Get-OmpModelIds([string[]]$lines) {
    $provBlock = Find-YamlBlock $lines "9router" 2
    if (-not $provBlock) { return [string[]]@() }
    $mb = Find-YamlBlock $lines "models" 4 $provBlock.ContentStart $provBlock.End
    if (-not $mb) { return [string[]]@() }
    $out = @()
    for ($i = $mb.ContentStart; $i -lt $mb.End; $i++) {
        # Anchored to the sequence-item indent, so a nested `id:` inside a model
        # definition is not mistaken for the model's own id.
        if ($lines[$i] -match '^\s{6}- id:\s*(.+?)\s*$') { $out += $Matches[1] }
    }
    return [string[]]$out
}

function Write-OmpConfig([string]$defaultId) {
    $tool = "omp"
    $modelsPath = Join-Path $env:USERPROFILE ".omp\agent\models.yml"
    $cfgPath = Join-Path $env:USERPROFILE ".omp\agent\config.yml"
    $validIds = @($script:Models | ForEach-Object { $_.id })
    # Same prefix rule as the opencode pin check: pins are bare names,
    # resolved ids can carry 9router/.
    $strippedValid = @($validIds | ForEach-Object { "$_" -replace '^9router/', '' })

    if (-not (Test-Path -LiteralPath $modelsPath)) {
        Write-Warn "omp -> not installed on this PC, skipped."
        Write-Warn "       no models.yml at $modelsPath"
        Write-Warn "       install omp first, or drop 'omp' from tools in Settings."
        Add-Report $tool $modelsPath "not-installed" "omp is not installed on this PC (no models.yml)"
        return
    }

    $info = Read-ToolFile $modelsPath
    $lines = ConvertTo-YamlLines $info.Text
    if ($lines.Count -eq 0) {
        Write-Err "omp -> models.yml is empty."
        Add-Report $tool $modelsPath "failed" "models.yml is empty"
        return
    }

    $before = @(Get-OmpModelIds $lines)

    $provBlock = Find-YamlBlock $lines "9router" 2
    if (-not $provBlock) {
        Write-Warn "omp -> no providers.9router block in models.yml, skipped."
        Add-Report $tool $modelsPath "skipped" "no providers.9router block in models.yml"
        return
    }

    # Connection fields sit at indent 4 under providers.9router. authHeader,
    # disableStrictTools, headers and discovery are left alone.
    $lines = Set-YamlScalar $lines $provBlock "baseUrl" $script:ApiBase 4
    $provBlock = Find-YamlBlock $lines "9router" 2
    $lines = Set-YamlScalar $lines $provBlock "apiKey" $script:ApiKey 4

    # Rebuilt inside providers.9router only.
    $body = @("    models:")
    foreach ($m in $script:Models) {
        $body += "      - id: $(Format-YamlScalar $m.id)"
        $body += "        name: $(Format-YamlScalar $m.id)"
        $body += "        contextWindow: $($m.ctx)"
        $body += "        maxTokens: $($m.maxOut)"
        $body += "        reasoning: $($m.reasoning.ToString().ToLowerInvariant())"
        $body += "        input:"
        $body += "          - text"
        if ($m.vision) { $body += "          - image" }
        $body += "        supportsTools: $($m.tools.ToString().ToLowerInvariant())"
    }
    # $body is the complete block including its header, so an existing models: is
    # replaced rather than having a second one appended underneath it.
    $provBlock = Find-YamlBlock $lines "9router" 2
    $mb = Find-YamlBlock $lines "models" 4 $provBlock.ContentStart $provBlock.End
    if ($mb) { $lines = Replace-YamlBlock $lines $mb $body 4 }
    else {
        # Inside the provider block, not at end of file. Appending to the file
        # put it under whichever unrelated top-level block came last.
        $lines = Splice-Lines $lines $provBlock.End 0 $body
    }

    Add-Change $tool $modelsPath $before $validIds
    $res = Write-ToolFile $modelsPath ((@($lines) -join "`n") + "`n") $info $script:BackupKeep
    Add-Report $tool $modelsPath (ConvertTo-WriteStatus $res) "$($script:Models.Count) models in models.yml"

    if (-not (Test-Path -LiteralPath $cfgPath)) {
        # models.yml exists but config.yml does not: omp is present but unusual.
        # Reported distinctly, because the two need different fixes.
        Add-Report $tool $cfgPath "skipped" "no config.yml (models.yml exists, so omp is installed but incomplete)"
        return
    }

    $cInfo = Read-ToolFile $cfgPath
    $clines = ConvertTo-YamlLines $cInfo.Text
    $rb = Find-YamlBlock $clines "modelRoles" 0
    if (-not $rb) {
        Write-Warn "omp -> no modelRoles in config.yml, default left alone."
        Add-Report $tool $cfgPath "skipped" "no modelRoles in config.yml"
        return
    }

    $hasDefault = Test-YamlKey $clines $rb "default" 2
    if ($hasDefault) {
        $clines = Set-YamlScalar $clines $rb "default" "9router/$defaultId" 2
    } else {
        $clines = Splice-Lines $clines $rb.End 0 @("  default: $(Format-YamlScalar "9router/$defaultId")")
        Write-Warn "omp -> no modelRoles.default, added it."
    }

    # Re-found: the insert above changed the line count the previous block
    # bounds described, and scanning the stale range stopped one line short -
    # which is exactly where the role to be released can sit.
    $rb = Find-YamlBlock $clines "modelRoles" 0
    $drop = @()
    for ($i = $rb.ContentStart; $i -lt $rb.End; $i++) {
        if ($clines[$i] -notmatch '^\s+([\w-]+)\s*:\s*(\S.*?)\s*$') { continue }
        $role = $Matches[1]; $raw = $Matches[2]
        if ($role -eq "default") { continue }
        $pin = Get-ModelPin $raw
        if ($pin -and $pin.Provider -eq "9router" -and ($strippedValid -notcontains ($pin.Model -replace '^9router/', ''))) {
            $drop += [pscustomobject]@{ Role = $role; Model = $pin.Model }
        }
    }
    foreach ($d in $drop) {
        $b = Find-YamlBlock $clines "modelRoles" 0
        $clines = Remove-YamlKey $clines $b $d.Role 2
        Add-Dangling $tool "modelRoles.$($d.Role)" $d.Model
        Write-Warn "omp -> modelRoles.$($d.Role) was pinned to a model that is gone, released."
    }

    $res2 = Write-ToolFile $cfgPath ((@($clines) -join "`n") + "`n") $cInfo $script:BackupKeep
    Add-Report $tool $cfgPath (ConvertTo-WriteStatus $res2) "modelRoles.default = 9router/$defaultId"
}