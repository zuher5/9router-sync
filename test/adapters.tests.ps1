# End-to-end adapter tests. Each runs the real writer against a temp file and
# reads the result back, so the YAML/TOML/JSON on disk is what is asserted - not
# an intermediate structure.

# $models must be typed as [string[]]: bound as [string] the array is joined into
# one space-separated value, which is exactly the kind of scalar/array confusion
# this rewrite is meant to be free of.
function Invoke-Adapter([scriptblock]$body, [string[]]$models) {
    $script:Models = @()
    $models | ForEach-Object {
        $script:Models += [pscustomobject]@{
            id = $_; ctx = 128000; maxOut = 4096
            vision = $false; reasoning = $false; tools = $true
            requestedAs = $_; wasRenamed = $false
        }
    }
    $script:ApiBase = "http://192.168.0.4:20128/v1"
    $script:ApiKey = "sk-test-key"
    $script:Report = @(); $script:Changes = @(); $script:Dangling = @()
    $script:BackupKeep = 3
    $script:ShouldWrite = { param([string]$path) return $true }
    & $body
    return @($script:Report)
}

function Get-TempDir {
    $d = Join-Path $env:TEMP ("9sync-adapter-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# --- hermes ----------------------------------------------------------------

Test-Case "hermes: the provider block is created when absent, other providers survive" {
    $dir = Get-TempDir
    $cfg = Join-Path $dir "config.yaml"
    $orig = @"
display:
  in_app_tips: false
model:
  default: mimo-v2.6-flash
  provider: wahyu
  base_url: https://bansos.example/v1
  api_mode: chat_completions
  key_env: HERMES_CUSTOM_WAHYU_API_KEY
providers:
  wahyu:
    name: wahyu
    base_url: https://bansos.example/v1
    model: mimo-v2.6-flash
    discover_models: true
    models:
      mimo-v2.6-flash: {}
    key_env: HERMES_CUSTOM_WAHYU_API_KEY
_config_version: 50
onboarding:
  seen:
    profile_build_offered: true
"@
    [System.IO.File]::WriteAllText($cfg, $orig, (New-Object System.Text.UTF8Encoding($false)))

    $body = {
        $p = $cfg
        $base = Split-Path -Parent $p
        $envPath = Join-Path $base ".env"
        $validIds = @($script:Models | ForEach-Object { $_.id })
        $info = Read-ToolFile $p
        $lines = ConvertTo-YamlLines $info.Text
        $before = @(Get-HermesModelIds $lines)
        $provName = "9router"
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "default" "9router/one-day/glm" 2
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "provider" $provName 2
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "base_url" $script:ApiBase 2
        $mb = Find-YamlBlock $lines "model" 0
        $lines = Set-YamlScalar $lines $mb "key_env" "OPENAI_API_KEY" 2
        $providersBlock = Find-YamlBlock $lines "providers" 0
        $pb = Find-YamlBlock $lines $provName 2 $providersBlock.ContentStart $providersBlock.End
        $newProv = @(
            "  9router:"
            "    name: 9router"
            "    base_url: $(Format-YamlScalar $script:ApiBase)"
            "    key_env: OPENAI_API_KEY"
            "    model: $(Format-YamlScalar "9router/one-day/glm")"
            "    default_model: $(Format-YamlScalar "9router/one-day/glm")"
            "    discover_models: false"
            "    models:"
        )
        foreach ($m in $script:Models) { $newProv += "      $(Format-YamlScalar $m.id): {}" }
        $providersBlock = Find-YamlBlock $lines "providers" 0
        $lines = Splice-Lines $lines $providersBlock.End 0 $newProv
        Add-Change "hermes" $p $before $validIds
        $r = Write-ToolFile $p ((@($lines) -join "`n") + "`n") $info $script:BackupKeep
        Add-Report "hermes" $p (ConvertTo-WriteStatus $r) "test"
    }
    Invoke-Adapter $body @("9router/one-day/glm", "openrouter/free#1") | Out-Null

    $after = Read-ToolFile $cfg
    $text = $after.Text
    Assert-Contains $text "9router:"
    Assert-Contains $text "bansos.example" "the wahyu provider must be preserved"
    Assert-Contains $text "HERMES_CUSTOM_WAHYU_API_KEY" "its key_env must be preserved"
    Assert-Contains $text "9router/one-day/glm: {}" "the 9router model list lives under its own provider"
    Assert-Contains $text "openrouter/free#1: {}" "a mid-word # stays a plain scalar"

    # _config_version must still be a top-level key, not absorbed.
    $lines = ConvertTo-YamlLines $text
    $cv = Find-YamlBlock $lines "_config_version" 0
    Assert-True ($null -ne $cv) "_config_version must stay at the top level"
    Assert-Equal $lines[$cv.Start] "_config_version: 50"

    $onb = Find-YamlBlock $lines "onboarding" 0
    Assert-True ($null -ne $onb) "onboarding must stay at the top level"

    Remove-Item -LiteralPath $dir -Recurse -Force
}

Test-Case "hermes: a second run over the same file is byte-identical" {
    $dir = Get-TempDir
    $cfg = Join-Path $dir "config.yaml"
    $seed = @"
model:
  default: a/b
  provider: 9router
  base_url: http://192.168.0.4:20128/v1
  key_env: OPENAI_API_KEY
providers:
  9router:
    name: 9router
    base_url: http://192.168.0.4:20128/v1
    key_env: OPENAI_API_KEY
    model: a/b
    default_model: a/b
    discover_models: false
    models:
      a/b: {}
"@
    [System.IO.File]::WriteAllText($cfg, $seed, (New-Object System.Text.UTF8Encoding($false)))

    $body = {
        $info = Read-ToolFile $cfg
        $r = Write-ToolFile $cfg $info.Text $info 3
        Add-Report "hermes" $cfg (ConvertTo-WriteStatus $r) "test"
    }
    $rows = Invoke-Adapter $body @("a/b")
    $res = @($rows)[0]
    Assert-Equal $res.Status "unchanged" "identical content must not be rewritten"

    Remove-Item -LiteralPath $dir -Recurse -Force
}

# --- toml ------------------------------------------------------------------

Test-Case "codex: writes stay out of foreign sections" {
    $dir = Get-TempDir
    $toml = Join-Path $dir "config.toml"
    $seed = @"
model_provider = "openai"
model = "gpt-5"

[profiles.work]
model = "o3"

[model_providers.other]
base_url = "https://other/v1"
api_key = "sk-other"
"@
    [System.IO.File]::WriteAllText($toml, $seed, (New-Object System.Text.UTF8Encoding($false)))

    $info = Read-ToolFile $toml
    $lines = ConvertTo-YamlLines $info.Text
    $lines = Set-TomlKey $lines "base_url" "http://192.168.0.4:20128/v1" ""
    $lines = Set-TomlKey $lines "api_key" "sk-test" ""
    $lines = Set-TomlKey $lines "model" "9router/a/b" ""

    Assert-Equal (Get-TomlKey $lines "base_url" "") "http://192.168.0.4:20128/v1"
    Assert-Equal (Get-TomlKey $lines "base_url" "model_providers.other") "https://other/v1" "foreign base_url preserved"
    Assert-Equal (Get-TomlKey $lines "api_key" "model_providers.other") "sk-other" "foreign api_key preserved"
    Assert-Equal (Get-TomlKey $lines "model" "profiles.work") "o3" "a profile's own model preserved"
    Test-TomlParses (($lines -join "`n"))
    Assert-True ((Get-TomlSections $lines) -contains "profiles.work")

    Remove-Item -LiteralPath $dir -Recurse -Force
}

# --- json ------------------------------------------------------------------

Test-Case "opencode: providers and unrelated keys survive a merge" {
    $dir = Get-TempDir
    $cfg = Join-Path $dir "opencode.json"
    $seed = @'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "9router/old/model",
  "mcp": { "some-server": { "type": "local" } },
  "agents": { "explorer": { "model": "9router/gone/model", "description": "keeps this" } },
  "providers": {
    "other": { "package": "other-pkg", "models": { "keep/me": {} } }
  }
}
'@
    [System.IO.File]::WriteAllText($cfg, $seed, (New-Object System.Text.UTF8Encoding($false)))

    $info = Read-ToolFile $cfg
    $c = ConvertTo-JsonOrNull $info.Text
    $before = @(Get-OpenCodeModelIds $c)
    Assert-Equal ($before -join ",") "" "no 9router provider yet"

    $models = [ordered]@{}
    foreach ($m in @("a/one", "a/two")) { $models[$m] = [ordered]@{ name = $m } }
    $providers = [ordered]@{}
    foreach ($p in $c.providers.PSObject.Properties) { if ($p.Name -ne "9router") { $providers[$p.Name] = $p.Value } }
    $providers["9router"] = [ordered]@{ package = "aisdk:@ai-sdk/openai-compatible"; settings = [ordered]@{ baseURL = "http://x/v1" }; models = $models }

    $agents = [ordered]@{}
    foreach ($ap in $c.agents.PSObject.Properties) {
        $e = [ordered]@{}
        foreach ($ep in $ap.Value.PSObject.Properties) { if ($ep.Name -ne "model") { $e[$ep.Name] = $ep.Value } }
        $agents[$ap.Name] = $e
        Add-Dangling "opencode" "agents.$($ap.Name).model" "gone/model"
    }

    $out = [ordered]@{}
    foreach ($p in $c.PSObject.Properties) {
        if ($p.Name -eq "providers") { $out["providers"] = $providers }
        elseif ($p.Name -eq "agents") { $out["agents"] = $agents }
        else { $out[$p.Name] = $p.Value }
    }
    $out["model"] = "9router/a/one"
    $r = Write-ToolFile $cfg ((ConvertTo-JsonText $out) + "`n") $info 3
    Assert-Equal $r "written"

    $after = ConvertTo-JsonOrNull (Read-ToolFile $cfg).Text
    Assert-Equal $after.model "9router/a/one"
    Assert-True ($null -ne $after.mcp) "mcp survives"
    Assert-True ($null -ne $after.providers.other) "another provider survives"
    Assert-True ($null -eq $after.agents.explorer.model) "the dangling pin is released"
    Assert-Equal $after.agents.explorer.description "keeps this" "the agent itself is kept"
    Assert-Equal (@($script:Dangling).Count) 1
    Assert-Equal (@(Get-OpenCodeModelIds $after) -join ",") "a/one,a/two"

    Remove-Item -LiteralPath $dir -Recurse -Force
}

Test-Case "json: a model id starting with PS is not dropped" {
    $models = [ordered]@{ "PS-secret-model" = [ordered]@{ name = "PS-secret-model" } }
    $cfg = [ordered]@{ providers = [ordered]@{ "9router" = [ordered]@{ models = $models } } }
    $text = ConvertTo-JsonText $cfg
    Assert-Contains $text "PS-secret-model"
    $back = ConvertTo-JsonOrNull $text
    Assert-Equal ((@(Get-OpenCodeModelIds $back) -join ",")) "PS-secret-model"
}

# --- encoding --------------------------------------------------------------

Test-Case "encoding: an ANSI file is read and written back without corruption" {
    $dir = Get-TempDir
    $p = Join-Path $dir "models.yml"
    # Byte 0x92 is a cp1252 right single quote and is not valid UTF-8. Building
    # the bytes by hand rather than via GetBytes, because the round trip through
    # a .NET string literal would normalise it away.
    $text = "name: " + [char]0x2019 + "quoted" + "`n"
    $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($text)
    Assert-Equal ([int]$bytes[6]) 146 "0x92, the cp1252 right single quote"
    [System.IO.File]::WriteAllBytes($p, $bytes)

    $info = Read-ToolFile $p
    Assert-Equal $info.IsUtf8 $false "must be detected as non-UTF-8"
    Assert-Equal $info.Encoding "windows-1252"
    Assert-Contains $info.Text ([char]0x2019) "the smart quote is decoded, not replaced"

    $lines = ConvertTo-YamlLines $info.Text
    $r = Write-ToolFile $p ((@($lines) -join "`n") + "`n") $info 3
    Assert-Equal $r "unchanged" "re-encoding the same text must not count as a change"

    $readBack = Read-ToolFile $p
    Assert-Contains $readBack.Text ([char]0x2019) "the byte survives the round trip"
    Assert-True ($readBack.Text -notmatch [char]0xFFFD) "no replacement character was baked in"

    Remove-Item -LiteralPath $dir -Recurse -Force
}

Test-Case "encoding: a UTF-8 file with a BOM is read without the BOM" {
    $dir = Get-TempDir
    $p = Join-Path $dir "c.json"
    [byte[]]$all = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{"a":1}')
    [System.IO.File]::WriteAllBytes($p, $all)

    $info = Read-ToolFile $p
    Assert-Equal $info.IsUtf8 $true
    Assert-Equal $info.Text '{"a":1}'
    Assert-True ($info.Text.IndexOf([char]0xFEFF) -lt 0) "the BOM must be stripped on read"

    # And a rewrite must not reintroduce one.
    Write-ToolFile $p '{"a":2}' $info 3 | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($p)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "no BOM is written back"

    Remove-Item -LiteralPath $dir -Recurse -Force
}

# --- backups ---------------------------------------------------------------

Test-Case "backup: the previous version is kept and pruned to backupKeep" {
    $dir = Get-TempDir
    $p = Join-Path $dir "f.txt"
    $script:ShouldWrite = { param([string]$path) return $true }
    for ($i = 1; $i -le 6; $i++) {
        [System.IO.File]::WriteAllText($p, "v$i", (New-Object System.Text.UTF8Encoding($false)))
        $info = Read-ToolFile $p
        Start-Sleep -Milliseconds 5
        Write-ToolFile $p "w$i" $info 3 | Out-Null
    }
    $baks = @(Get-Backups $p)
    Assert-True ($baks.Count -le 3) "at most backupKeep=3 backups, found $($baks.Count)"
    Assert-Equal (Read-ToolFile $p).Text "w6"
    Remove-Item -LiteralPath $dir -Recurse -Force
}

Test-Case "backup: two writes in the same second do not collide" {
    $dir = Get-TempDir
    $p = Join-Path $dir "f.txt"
    $script:ShouldWrite = { param([string]$path) return $true }
    [System.IO.File]::WriteAllText($p, "v1", (New-Object System.Text.UTF8Encoding($false)))
    $info = Read-ToolFile $p
    Write-ToolFile $p "a" $info 5 | Out-Null
    $info2 = Read-ToolFile $p
    Write-ToolFile $p "b" $info2 5 | Out-Null
    $baks = @(Get-Backups $p)
    Assert-True ($baks.Count -eq 2) "each write needs its own backup, found $($baks.Count)"
    Remove-Item -LiteralPath $dir -Recurse -Force
}