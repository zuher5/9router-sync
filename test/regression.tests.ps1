# Regression tests for the defects found in the pre-rewrite engine.
# Each name refers to something that was observably wrong, not a hypothetical.

Test-Case "omp: models block lookup is scoped to providers.9router" {
    $lines = [string[]]@(
        "providers:",
        "  other:",
        "    baseUrl: https://other.example/v1",
        "    models:",
        "      - id: other-model",
        "  9router:",
        "    baseUrl: http://old/v1",
        "    models:",
        "      - id: stale-9r-model"
    )
    # What the old code returned: the first models: at indent 4, other-model.
    $before = @(Get-OmpModelIds $lines)
    Assert-Equal ($before -join ",") "stale-9r-model" "should read the 9router block, not the first one in the file"
}

Test-Case "omp: unscoped lookup would have picked the wrong provider (guard)" {
    $lines = [string[]]@(
        "providers:",
        "  other:",
        "    models:",
        "      - id: other-model",
        "  9router:",
        "    models:",
        "      - id: nine-router"
    )
    $unscoped = Find-YamlBlock $lines "models" 4
    $prov = Find-YamlBlock $lines "9router" 2
    $scoped = Find-YamlBlock $lines "models" 4 $prov.ContentStart $prov.End
    Assert-True ($scoped.Start -gt $unscoped.Start) "scoped lookup must point past the other provider"
}

Test-Case "omp: models written when 9router has no models key stay inside the block" {
    $lines = [string[]]@(
        "providers:",
        "  9router:",
        "    baseUrl: http://old/v1",
        "discovery:",
        "  cache: true"
    )
    $prov = Find-YamlBlock $lines "9router" 2
    $body = @("    models:", "      - id: a/b")
    $out = Splice-Lines $lines $prov.End 0 $body
    $text = $out -join "`n"
    Assert-Contains $text "cache: true"
    $discIdx = [array]::IndexOf($out, "  cache: true")
    $modelIdx = [array]::IndexOf($out, "      - id: a/b")
    Assert-True ($modelIdx -lt $discIdx) "the models list must not land inside the discovery block"
}

Test-Case "yaml: splice at end of array does not duplicate the last line" {
    $lines = [string[]]@("modelRoles:")
    $out = Splice-Lines $lines 1 0 @("  default: x")
    Assert-Equal $out.Count 2
    Assert-Equal $out[0] "modelRoles:"
    Assert-Equal $out[1] "  default: x"
}

Test-Case "yaml: splice into an empty region returns exactly the replacement" {
    $out = Splice-Lines ([string[]]@()) 0 0 @("a:", "  b: 1")
    Assert-Equal $out.Count 2
    Assert-Equal $out[0] "a:"
}

Test-Case "yaml: splice with empty replacement removes the range" {
    $lines = [string[]]@("a:", "  b: 1", "  c: 2", "d:")
    $out = Splice-Lines $lines 1 2 @()
    Assert-Equal ($out -join "|") "a:|d:"
}

Test-Case "yaml: map keys with a colon read back whole, not truncated" {
    $lines = [string[]]@(
        "providers:",
        "  9router:",
        "    models:",
        "      GratisanCok: {}",
        "      xkiro/qwen/qwen3.8-max:free: {}"
    )
    $prov = Find-YamlBlock $lines "9router" 2
    $keys = @(Get-YamlMapKeys $lines $prov "models" 4)
    Assert-Equal ($keys -join ",") "GratisanCok,xkiro/qwen/qwen3.8-max:free" "splitting at the first colon truncated the id and faked a removal every sync"
}

Test-Case "yaml: quoted map keys with a colon read back whole" {
    $lines = [string[]]@(
        "providers:",
        "  9router:",
        "    models:",
        '      "xkiro/qwen/qwen3.8-max:free": {}'
    )
    $prov = Find-YamlBlock $lines "9router" 2
    $keys = @(Get-YamlMapKeys $lines $prov "models" 4)
    Assert-Equal ($keys -join ",") "xkiro/qwen/qwen3.8-max:free"
}

Test-Case "hermes: a colon id survives a read-back without phantom changes" {
    $lines = [string[]]@(
        "providers:",
        "  9router:",
        "    models:",
        "      xkiro/qwen/qwen3.8-max:free: {}"
    )
    $before = @(Get-HermesModelIds $lines)
    $after = @("xkiro/qwen/qwen3.8-max:free")
    $removed = @($before | Where-Object { $after -notcontains $_ })
    $added = @($after | Where-Object { $before -notcontains $_ })
    Assert-Equal @($removed).Count 0 "no phantom removal"
    Assert-Equal @($added).Count 0 "no phantom add"
}

Test-Case "toml: a key is written inside its own section, not another one" {
    $lines = [string[]]@(
        'model_provider = "openai"',
        'model = "gpt-5"',
        '[profiles.work]',
        'model = "o3"',
        '[model_providers.other]',
        'base_url = "https://other/v1"'
    )
    $out = Set-TomlKey $lines "base_url" "http://9router/v1" ""
    $top = Find-TomlKey $out "base_url" ""
    $other = Find-TomlKey $out "base_url" "model_providers.other"
    Assert-True ($null -ne $top) "top-level base_url must be set"
    Assert-Equal $out[$top.Line] 'base_url = "http://9router/v1"'
    # The other provider keeps its own endpoint: same key name, different section.
    Assert-True ($null -ne $other) "the foreign section's base_url must still exist"
    Assert-Equal $out[$other.Line] 'base_url = "https://other/v1"' "untouched"
    Assert-True ($other.Line -ne $top.Line) "the two must be different lines"
}

Test-Case "toml: a missing key is inserted into its section, not at end of file" {
    $lines = [string[]]@(
        'model = "gpt-5"',
        '[model_providers.other]',
        'base_url = "https://other/v1"'
    )
    $out = Set-TomlKey $lines "api_key" "sk-secret" ""
    Assert-Equal (Get-TomlKey $out "api_key" "") "sk-secret"
    # The appended key must precede the first section header.
    $keyIdx = (Find-TomlKey $out "api_key" "").Line
    $hdrIdx = [array]::IndexOf($out, '[model_providers.other]')
    Assert-True ($keyIdx -lt $hdrIdx) "api_key landed inside [model_providers.other]"
}

Test-Case "toml: a missing section is created for the key" {
    $lines = [string[]]@('model = "gpt-5"')
    $out = Set-TomlKey $lines "base_url" "http://x/v1" "model_providers.9router"
    Assert-True (Test-TomlSection $out "model_providers.9router")
    Assert-Equal (Get-TomlKey $out "base_url" "model_providers.9router") "http://x/v1"
}

Test-Case "resolve: an omitted tools capability stays enabled" {
    $catalog = @(
        [pscustomobject]@{ id = "m1"; capabilities = [pscustomobject]@{ contextWindow = 1000; maxOutput = 10 } }
    )
    $models = Resolve-Models @("m1") $catalog @{}
    Assert-Equal (@($models)[0].tools) "True" "omitting the field must not disable tool calling"
}

Test-Case "resolve: a string 'false' means false" {
    $catalog = @(
        [pscustomobject]@{ id = "m1"; capabilities = [pscustomobject]@{ vision = "false"; tools = "false" } }
    )
    $models = Resolve-Models @("m1") $catalog @{}
    Assert-Equal (@($models)[0].vision) "False"
    Assert-Equal (@($models)[0].tools) "False"
}

Test-Case "resolve: an explicit tools=false is honoured" {
    $catalog = @(
        [pscustomobject]@{ id = "m1"; capabilities = [pscustomobject]@{ tools = $false } }
    )
    $models = Resolve-Models @("m1") $catalog @{}
    Assert-Equal (@($models)[0].tools) "False"
}

Test-Case "resolve: two ids aliasing to the same model produce one entry" {
    $catalog = @(
        [pscustomobject]@{ id = "real"; capabilities = [pscustomobject]@{} }
    )
    $models = Resolve-Models @("old-a", "old-b") $catalog @{ "old-a" = "real"; "old-b" = "real" }
    Assert-Equal @($models).Count 1
    Assert-Equal (@($models)[0].id) "real"
}

Test-Case "resolve: quoted 9router pins are recognised" {
    $p = Get-ModelPin '"9router/some/model"'
    Assert-Equal $p.Model "some/model"
    $p2 = Get-ModelPin '9router/plain'
    Assert-Equal $p2.Model "plain"
    Assert-Equal (Get-ModelPin '"openrouter/other"') $null "another provider is not a 9router pin"
}

Test-Case "resolve: model ids are collected from map, array and string shapes" {
    $payload = [pscustomobject]@{
        opencode = [pscustomobject]@{
            config = [pscustomobject]@{
                provider = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = [pscustomobject]@{ "a/one" = @{}; "a/two" = @{} } }
                }
            }
        }
        pi = [pscustomobject]@{
            config = [pscustomobject]@{
                provider = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = @([pscustomobject]@{ id = "b/three" }) }
                }
            }
        }
        claude = [pscustomobject]@{ config = $null }
    }
    $wanted = Collect-WantedModelIds $payload
    Assert-Contains ($wanted.Ids -join ",") "a/one"
    Assert-Contains ($wanted.Ids -join ",") "a/two"
    Assert-Contains ($wanted.Ids -join ",") "b/three"
    Assert-Equal $wanted.Ids.Count 3 "duplicate ids across tools collapse"
}

Test-Case "resolve: only the singular provider key is consumed, plural is stale" {
    $payload = [pscustomobject]@{
        opencode = [pscustomobject]@{
            config = [pscustomobject]@{
                providers = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = [pscustomobject]@{ "stale/deleted" = @{} } }
                }
                provider = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = [pscustomobject]@{ "b/two" = @{} } }
                }
            }
        }
        pi = [pscustomobject]@{
            config = [pscustomobject]@{
                providers = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = @([pscustomobject]@{ id = "anoman/old" }) }
                }
            }
        }
    }
    $wanted = Collect-WantedModelIds $payload
    Assert-Contains ($wanted.Ids -join ",") "b/two"
    Assert-Equal (@($wanted.Ids -join ",").IndexOf("stale/deleted")) -1 "a deleted model in the stale plural key must not leak back"
    Assert-Equal (@($wanted.Ids -join ",").IndexOf("anoman/old")) -1 "a tool without the singular key contributes nothing"
}

Test-Case "resolve: phone top-level model is collected and reported as phone default" {
    $payload = [pscustomobject]@{
        opencode = [pscustomobject]@{
            config = [pscustomobject]@{
                provider = [pscustomobject]@{
                    "9router" = [pscustomobject]@{ models = [pscustomobject]@{ "a/one" = @{} } }
                }
                model = "9router/b/two"
            }
        }
    }
    $wanted = Collect-WantedModelIds $payload
    Assert-Contains ($wanted.Ids -join ",") "a/one"
    Assert-Contains ($wanted.Ids -join ",") "b/two"
    Assert-Equal (@($wanted.Ids)).Count 2 "prefixed phone default merges, no extra entry"
    Assert-Equal (@($wanted.PhoneDefault))[0] "b/two" "stored stripped of the 9router/ prefix"
}

Test-Case "resolve: pi settings defaultModel is collected as a phone default" {
    $payload = [pscustomobject]@{
        pi = [pscustomobject]@{
            settings = [pscustomobject]@{ defaultModel = "9router/c/three" }
        }
    }
    $wanted = Collect-WantedModelIds $payload
    Assert-Contains ($wanted.Ids -join ",") "c/three"
    Assert-Equal (@($wanted.PhoneDefault))[0] "c/three"
}

Test-Case "resolve: ids missing from the catalog are mirrored, not dropped" {
    $models = Resolve-Models @("ghost/model") @() @{}
    Assert-Equal @($models).Count 1 "a phone-configured id must survive the catalog gate"
    Assert-Equal (@($models)[0].id) "ghost/model"
    Assert-Equal (@($models)[0].tools) "True"
}

Test-Case "resolve: a prefixed id and its bare twin collapse to one entry" {
    $catalog = @([pscustomobject]@{
        id = "vendor/model"
        capabilities = [pscustomobject]@{ contextWindow = 999; maxOutput = 111 }
    })
    $models = Resolve-Models @("9router/vendor/model", "vendor/model") $catalog @{}
    Assert-Equal @($models).Count 1 "9router/X and X name the same model"
    Assert-Equal (@($models)[0].ctx) 999 "the catalog hit wins over the mirror"
}

Test-Case "json: numeric types that used to serialise as {} are written as numbers" {
    Assert-Equal (ConvertTo-JsonText ([single]0.5)) "0.5"
    Assert-Equal (ConvertTo-JsonText ([byte]7)) "7"
    Assert-Equal (ConvertTo-JsonText ([uint64]5)) "5"
}

Test-Case "json: a char serialises as a string, not a one-element array" {
    Assert-Equal (ConvertTo-JsonText ([char]'a')) '"a"'
}

Test-Case "json: properties whose names start with PS are kept" {
    $o = [pscustomobject]@{ PSModel = 1; Normal = 2 }
    $json = ConvertTo-JsonText $o
    Assert-Contains $json "PSModel" "a model id starting with PS must survive"
}

Test-Case "json: strings are escaped rather than emitted raw" {
    $json = ConvertTo-JsonText ([ordered]@{ k = "a`"b`nc" })
    Assert-Contains $json '\"'
    Assert-Contains $json '\n'
}

Test-Case "yaml: a value needing quotes is quoted, a plain one is not" {
    # '#' only starts a comment when it begins the value or follows a space,
    # so these are the cases that actually need quoting.
    Assert-Equal (Format-YamlScalar "#leading") '"#leading"'
    Assert-Equal (Format-YamlScalar "has space #hash") '"has space #hash"'
    Assert-Equal (Format-YamlScalar "openrouter/free#1") "openrouter/free#1" "a mid-word # is a plain scalar"
    Assert-Equal (Format-YamlScalar "true") '"true"' "a bare true would parse as a boolean"
    Assert-Equal (Format-YamlScalar "123") '"123"' "a bare 123 would parse as a number"
    Assert-Equal (Format-YamlScalar "- dash") '"- dash"'
    Assert-Equal (Format-YamlScalar "vendor/model") "vendor/model" "ordinary ids stay bare"
}

Test-Case "yaml: a quoted id survives a round trip through the editor" {
    $lines = [string[]]@("models:", "  a: {}")
    $b = Find-YamlBlock $lines "models" 0
    $out = Set-YamlScalar $lines $b "has space #hash" "x" 2
    Assert-Contains ($out -join "`n") '"has space #hash"'
}

Test-Case "status: the worst row wins, not the last one" {
    $rows = @(
        [pscustomobject]@{ Status = "updated" }
        [pscustomobject]@{ Status = "skipped" }
    )
    Assert-Equal (Resolve-ToolStatus $rows) "updated" "a rewrite is not downgraded by a later skip"

    $rows2 = @(
        [pscustomobject]@{ Status = "updated" }
        [pscustomobject]@{ Status = "failed" }
    )
    Assert-Equal (Resolve-ToolStatus $rows2) "failed"
}

Test-Case "tools: every registered tool has metadata and a path" {
    foreach ($t in $script:AllTools) {
        Assert-True ($script:ToolMeta.Contains($t)) "no metadata for $t"
        $paths = @(Get-ToolConfigPaths $t)
        Assert-True ($paths.Count -gt 0) "no path for $t"
        Assert-True ($paths[0].Length -gt 0) "empty path for $t"
    }
}

Test-Case "tools: omp is registered but not a default" {
    Assert-True ($script:AllTools -contains "omp") "omp must stay registered"
    Assert-True ($script:ToolMeta["omp"].Default -eq $false) "omp is not installed here, so not a default"
    Assert-True ($script:ConfigDefaults.tools -notcontains "omp")
}

Test-Case "config: an uppercase bridge key is normalised on every path" {
    Assert-Equal (Normalize-BridgeKey "  C26AD307  ") "c26ad307"
}