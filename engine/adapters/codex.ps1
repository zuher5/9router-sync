<#
    codex.ps1 - ~/.codex/config.toml

    Section-aware. A TOML key only has meaning inside its section, so base_url,
    api_key and model are written to the top-level table and never into
    [model_providers.*] or [profiles.*].
#>

function Get-CodexPath { return (Join-Path $env:USERPROFILE ".codex\config.toml") }

function Write-CodexConfig([string]$defaultId) {
    $tool = "codex"
    $path = Get-CodexPath

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "codex -> .codex\config.toml is missing, skipped."
        Write-Warn "         run codex once so it writes the config, then sync again."
        Add-Report $tool $path "not-installed" "codex has never been run on this PC (no config.toml)"
        return
    }

    $info = Read-ToolFile $path
    $lines = ConvertTo-YamlLines $info.Text

    $lines = Set-TomlKey $lines "base_url" $script:ApiBase ""
    $lines = Set-TomlKey $lines "api_key" $script:ApiKey ""
    $lines = Set-TomlKey $lines "model" "9router/$defaultId" ""

    # Codex picks its provider from model_provider, so pointing model at a
    # 9router id without this left the whole thing inert.
    $provider = "9router"
    if (Test-TomlSection $lines "model_providers.9router") { $provider = "9router" }
    if (-not (Find-TomlKey $lines "model_provider" "")) {
        $lines = Set-TomlKey $lines "model_provider" $provider ""
        $provBody = [string[]]@(
            "base_url = `"$script:ApiBase`"",
            "api_key = `"$script:ApiKey`""
        )
        if (-not (Test-TomlSection $lines "model_providers.9router")) {
            $lines = @($lines + @("", "[model_providers.9router]") + $provBody)
        } else {
            foreach ($pair in $provBody) {
                $k = ($pair -split "=", 2)[0].Trim()
                $v = ($pair -split "=", 2)[1].Trim().Trim([char[]]@('"'))
                $lines = Set-TomlKey $lines $k $v "model_providers.9router"
            }
        }
    }

    Add-Change $tool $path @() @($script:Models | ForEach-Object { $_.id })
    $res = Write-ToolFile $path ((@($lines) -join "`n") + "`n") $info $script:BackupKeep
    Add-Report $tool $path (ConvertTo-WriteStatus $res) "base_url, api_key, model -> 9router/$defaultId"
}