<#
    resolve.ps1 - turning what 9Router publishes into a model list.

    Pure functions: no network, no file IO. Everything here is directly testable.
#>

# Capabilities arrive from the catalog in whatever shape the upstream provider
# chose. A bare string "false" has to mean false, not [bool]"false" which is
# $true - that single cast is what made vision and tool-calling silently invert.
function ConvertTo-Bool($value, [bool]$Default) {
    if ($null -eq $value) { return $Default }
    if ($value -is [bool]) { return $value }
    if ($value -is [string]) {
        $s = $value.Trim().ToLowerInvariant()
        if ($s -eq "true" -or $s -eq "1" -or $s -eq "yes") { return $true }
        if ($s -eq "false" -or $s -eq "0" -or $s -eq "no") { return $false }
        return $Default
    }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
        return ([double]$value -ne 0)
    }
    return [bool]$value
}

function Get-CapabilityNumber($value, [int]$Default) {
    if ($null -eq $value) { return $Default }
    if ($value -is [string]) {
        $n = 0
        if ([int]::TryParse($value.Trim(), [ref]$n)) { return $n }
        return $Default
    }
    try { return [int]$value } catch { return $Default }
}

# Model ids in payload order. opencode stores them as a map, pi as an array of
# {id}, and some tools use a bare string - all three have to work without the
# script being taught about each tool in advance.
function Collect-WantedModelIds($statuses) {
    $wanted = New-Object System.Collections.ArrayList
    $seen = @{}
    $source = @{}
    $toolsUsed = New-Object System.Collections.ArrayList
    # Phone-side configured defaults, stripped of any 9router/ prefix, in the
    # order the tools reported them. The top-level model fields live outside
    # providers.9router.models, so without this list a default newly set on
    # the phone dashboard is invisible to the sync.
    $phoneDefaults = New-Object System.Collections.ArrayList

    $add = {
        param($rawId, [string]$toolName)
        if ($null -eq $rawId) { return }
        $id = "$rawId".Trim()
        if (-not $id -or $seen.ContainsKey($id)) { return }
        $seen[$id] = $true
        $source[$id] = $toolName
        [void]$wanted.Add($id)
    }

    $addDefault = {
        param($rawId, [string]$toolName)
        if ($null -eq $rawId) { return }
        $id = "$rawId".Trim()
        if (-not $id) { return }
        # Canonical ids carry no provider prefix (the catalog and the
        # providers lists both use the stripped form), so strip here: the
        # phone writes its default as "9router/vendor/model".
        $stripped = $id -replace '^9router/', ''
        if ($stripped -and -not ($phoneDefaults -contains $stripped)) { [void]$phoneDefaults.Add($stripped) }
        & $add $stripped $toolName
    }

    $collect = {
        param($cfg, [string]$toolName)
        if (-not $cfg) { return }
        # Dashboard authority: the phone's new implementation keeps the live
        # list under the singular `provider` key. The plural `providers` key
        # is the stale snapshot (deleted models linger there), so it is
        # ignored entirely - no fallback, otherwise the deleted models leak
        # back in through the union.
        if (-not ($cfg.PSObject.Properties.Name -contains "provider") -or -not $cfg.provider) { return }
        $p = $cfg.provider
        if ($p.PSObject.Properties.Name -notcontains "9router") { return }
        $nine = $p.'9router'
        if (-not $nine -or -not ($nine.PSObject.Properties.Name -contains "models")) { return }

        $models = $nine.models
        if (-not $models) { return }
        if ($models -is [string]) { & $add $models $toolName; return }

        $isList = $models -is [System.Collections.IEnumerable] -and
                  $models -isnot [System.Management.Automation.PSCustomObject]
        if ($isList) {
            foreach ($m in $models) {
                if ($m -is [string]) { & $add $m $toolName }
                elseif ($m -and ($m.PSObject.Properties.Name -contains "id")) { & $add $m.id $toolName }
            }
        } else {
            foreach ($prop in $models.PSObject.Properties) { & $add $prop.Name $toolName }
        }
    }

    foreach ($prop in $statuses.PSObject.Properties) {
        $entry = $prop.Value
        if (-not $entry) { continue }
        $names = $entry.PSObject.Properties.Name
        if ($names -contains "config" -and $entry.config) {
            & $collect $entry.config $prop.Name
            [void]$toolsUsed.Add($prop.Name)
        } elseif ($names -contains "settings" -and $entry.settings) {
            & $collect $entry.settings $prop.Name
            [void]$toolsUsed.Add($prop.Name)
        }
        # The phone's configured default lives outside providers.9router.models
        # (opencode top-level `model`, pi settings `defaultModel`, per-agent
        # pins). Collect it so a dashboard change is mirrored, not ignored.
        $cfgNode = $null
        if ($names -contains "config" -and $entry.config) { $cfgNode = $entry.config }
        elseif ($names -contains "settings" -and $entry.settings) { $cfgNode = $entry.settings }
        if ($cfgNode) {
            $cn = @($cfgNode.PSObject.Properties.Name)
            if (($cn -contains "model") -and ($cfgNode.model -is [string])) { & $addDefault $cfgNode.model $prop.Name }
            if (($cn -contains "defaultModel") -and ($cfgNode.defaultModel -is [string])) { & $addDefault $cfgNode.defaultModel $prop.Name }
            if (($cn -contains "models") -and $cfgNode.models -is [System.Collections.IEnumerable] -and $cfgNode.models -isnot [string] -and $cfgNode.models -isnot [System.Management.Automation.PSCustomObject]) {
                foreach ($m in $cfgNode.models) {
                    if ($m -is [string]) { & $add $m $prop.Name }
                    elseif ($m -and ($m.PSObject.Properties.Name -contains "id")) { & $add $m.id $prop.Name }
                }
            }
            if (($cn -contains "agents") -and $cfgNode.agents) {
                foreach ($ap in $cfgNode.agents.PSObject.Properties) {
                    $pin = Get-ModelPin $ap.Value
                    if ($pin -and $pin.Provider -eq "9router" -and $pin.Model) { & $addDefault $pin.Model $prop.Name }
                }
            }
        }
    }

    return [pscustomobject]@{
        Ids = @($wanted.ToArray())
        Sources = $source
        ToolsUsed = @($toolsUsed.ToArray())
        PhoneDefault = @($phoneDefaults.ToArray())
    }
}

function Resolve-Models($wantedIds, $catalog, $aliases) {
    $catalogById = @{}
    foreach ($m in $catalog) {
        if ($m -and $m.id) { $catalogById["$($m.id)"] = $m }
    }

    $resolved = New-Object System.Collections.ArrayList
    # Keyed on the stripped id: "9router/X" and "X" name the same model, so a
    # prefixed pin plus an unprefixed catalog hit (or vice versa) must not
    # write two entries for one model. A catalog hit always wins its slot
    # over a mirrored entry.
    $deduped = @{}

    foreach ($id in $wantedIds) {
        $lookup = $id
        $mapped = $false
        if (-not $catalogById.ContainsKey($lookup) -and $aliases.ContainsKey($lookup)) {
            $lookup = $aliases[$lookup]
            $mapped = $true
            Write-Info "Model '$id' is not in the catalog, mapped to '$lookup'."
        }
        $dedupeKey = "$lookup" -replace '^9router/', ''
        if (-not $catalogById.ContainsKey($lookup)) {
            # Mirror what the phone configured even when the catalog does not
            # (yet) know the id: default capabilities, tools on. Dropping it
            # here is what made a newly set phone default never reach the PC.
            # The dedup check comes first so an id whose twin is already
            # covered stays silent instead of crying "written as-is".
            if ($deduped.ContainsKey($dedupeKey)) {
                Write-Detail "Model '$id' resolves to '$lookup', which is already in the list."
                continue
            }
            Write-Warn "Model '$id' is not in the 9Router catalog; written as-is with default capabilities."
            $deduped[$dedupeKey] = [pscustomobject]@{ Index = $resolved.Count; Mirrored = $true }
            [void]$resolved.Add([pscustomobject]@{
                id = $lookup
                ctx = 128000
                maxOut = 16384
                vision = $false
                reasoning = $false
                tools = $true
                requestedAs = $id
                wasRenamed = $mapped
            })
            continue
        }

        $c = $catalogById[$lookup].capabilities
        $ctx = 128000; $maxOut = 16384
        $vision = $false; $reasoning = $false; $tools = $true
        if ($c) {
            $ctx = Get-CapabilityNumber $c.contextWindow $ctx
            $maxOut = Get-CapabilityNumber $c.maxOutput $maxOut
            # Only overridden when the capability actually says something.
            # $tools used to be assigned [bool]$c.tools unconditionally, so a
            # catalog that omits the field turned tool calling OFF for every
            # model it did not explicitly grant it to.
            $vision = ConvertTo-Bool $c.vision $vision
            $reasoning = ConvertTo-Bool $c.reasoning $reasoning
            if ($c.PSObject.Properties.Name -contains "tools") { $tools = ConvertTo-Bool $c.tools $tools }
        }

        $entry = [pscustomobject]@{
            id = $lookup
            ctx = $ctx
            maxOut = $maxOut
            vision = $vision
            reasoning = $reasoning
            tools = $tools
            requestedAs = $id
            wasRenamed = $mapped
        }

        # Two old ids can alias to the same current id. Without this the entry
        # appeared twice and the tool config was written with a duplicate model.
        if ($deduped.ContainsKey($dedupeKey)) {
            $slot = $deduped[$dedupeKey]
            if ($slot.Mirrored) {
                $resolved[$slot.Index] = $entry
                $slot.Mirrored = $false
                Write-Detail "Model '$id' resolves to '$lookup', replacing its mirrored entry."
            } else {
                Write-Detail "Model '$id' resolves to '$lookup', which is already in the list."
            }
            continue
        }
        $deduped[$dedupeKey] = [pscustomobject]@{ Index = $resolved.Count; Mirrored = $false }
        [void]$resolved.Add($entry)
    }
    return @($resolved.ToArray())
}

# A model reference pointing at 9router. Handles the string form, the object
# form opencode uses for agents, and values that arrive with surrounding quotes
# from a YAML rewrite - the quoted case used to be missed, so dangling pins were
# never released.
function Get-ModelPin($value) {
    if ($null -eq $value) { return $null }

    if ($value -is [string]) {
        $s = $value.Trim().Trim([char[]]@("'", '"'))
        if ($s -match '^9router/(.+)$') { return [pscustomobject]@{ Provider = "9router"; Model = $Matches[1] } }
        return $null
    }
    $names = $value.PSObject.Properties.Name
    if (($names -contains "providerID") -and ($names -contains "model")) {
        return [pscustomobject]@{ Provider = "$($value.providerID)"; Model = "$($value.model)" }
    }
    return $null
}