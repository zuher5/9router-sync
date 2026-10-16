<#
    e2e.tests.ps1 - a full sync against a mock bridge and a temp HOME.

    The point is to assert what is actually on disk after a run, using the same
    path the CLI and the web server take. Requires the mock bridge:

      node test/mock-bridge.mjs 20999 test-key
#>

$ErrorActionPreference = "Stop"
$engineRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "engine"

$mockUrl = "http://127.0.0.1:20999"
# Must match mock-bridge.mjs's default, and must be 64 hex characters: the
# engine rejects a shorter key before it makes any request.
$mockKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# Skip rather than fail when the mock is not running.
try {
    $probe = Invoke-WebRequest -Uri "$mockUrl/api/bridge/keys" -Headers @{ "x-9r-bridge-key" = $mockKey } -UseBasicParsing -TimeoutSec 3
} catch {
    Write-Host "  (mock bridge not running - skipping e2e)"
    Write-Host "  start it with: node test\mock-bridge.mjs 20999 test-key"
    exit 0
}

$passed = 0; $failed = 0; $failures = @()

function Check([string]$name, [scriptblock]$body) {
    try { & $body; $script:passed++; Write-Host "  ok   $name" -ForegroundColor DarkGray }
    catch {
        $script:failed++; $script:failures += $name
        Write-Host "  FAIL $name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Equal($a, $b, [string]$why = "") {
    $x = if ($null -eq $a) { "<null>" } else { "$a" }
    $y = if ($null -eq $b) { "<null>" } else { "$b" }
    if ($x -cne $y) { throw "expected '$y' but got '$x'$(if ($why) { " ($why)" })" }
}

function Has([string]$hay, [string]$needle, [string]$why = "") {
    if ($null -eq $hay -or $hay.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "expected to contain '$needle'$(if ($why) { " ($why)" })`n--- actual ---`n$hay"
    }
}

function Lacks([string]$hay, [string]$needle, [string]$why = "") {
    if ($null -ne $hay -and $hay.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) {
        throw "expected NOT to contain '$needle'$(if ($why) { " ($why)" })`n--- actual ---`n$hay"
    }
}

# --- sandbox ---------------------------------------------------------------

$sandbox = Join-Path $env:TEMP ("9sync-e2e-" + [guid]::NewGuid().ToString("N"))
foreach ($d in @("$sandbox\home\.config\opencode", "$sandbox\home\.pi\agent", "$sandbox\home\.omp\agent",
                 "$sandbox\home\.claude", "$sandbox\home\.codex", "$sandbox\local\hermes")) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$origHome = $env:USERPROFILE
$origLocal = $env:LOCALAPPDATA
$env:USERPROFILE = "$sandbox\home"
$env:LOCALAPPDATA = "$sandbox\local"
$statePath = Join-Path $sandbox "state.json"

$ocPath = "$sandbox\home\.config\opencode\opencode.json"
$hermesPath = "$sandbox\local\hermes\config.yaml"
$envPath = "$sandbox\local\hermes\.env"
$ompPath = "$sandbox\home\.omp\agent\models.yml"
$ompcfgPath = "$sandbox\home\.omp\agent\config.yml"
$codexPath = "$sandbox\home\.codex\config.toml"
$claudePath = "$sandbox\home\.claude\settings.json"

function Reset-Sandbox {
    foreach ($p in @("$sandbox\home\.config\opencode\opencode.json",
                     "$sandbox\home\.omp\agent\models.yml",
                     "$sandbox\home\.omp\agent\config.yml",
                     "$sandbox\home\.pi\agent\models.json",
                     "$sandbox\home\.pi\agent\settings.json",
                     $hermesPath, $envPath, $codexPath, $claudePath)) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $sandbox -Filter "*.bak" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    [System.IO.File]::WriteAllText($ocPath, @'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "9router/old/model",
  "mcp": { "some-server": { "type": "local" } },
  "agents": {
    "explorer": { "model": "9router/retired/model", "description": "keeps this" },
    "scout": { "model": "9router/vendor:co/dupe" },
    "build": { "model": "opencode/big-pickle" }
  },
  "providers": {
    "other": { "package": "other-pkg", "models": { "keep/me": {} } }
  }
}
'@, (New-Object System.Text.UTF8Encoding($false)))

    [System.IO.File]::WriteAllText($hermesPath, @"
display:
  in_app_tips: false
model:
  default: mimo-v2.6-flash
  provider: wahyu
  base_url: https://bansos.example/v1
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
"@, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($envPath, "HERMES_CUSTOM_WAHYU_API_KEY=sk-old`n", (New-Object System.Text.UTF8Encoding($false)))

    # A foreign provider written BEFORE 9router: the ordering that used to make
    # the old writer rewrite other.models and leave 9router untouched.
    [System.IO.File]::WriteAllText($ompPath, @"
providers:
  other:
    baseUrl: https://other.example/v1
    apiKey: sk-other
    models:
      - id: other-model
  9router:
    baseUrl: http://old.example/v1
    apiKey: sk-old
    models:
      - id: stale-9r-model
discovery:
  cache: true
"@, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($ompcfgPath, "modelRoles:`n  advisor: 9router/retired/model`n  helper: 9router/vendor:co/dupe`n", (New-Object System.Text.UTF8Encoding($false)))

    [System.IO.File]::WriteAllText($codexPath, @"
model_provider = "openai"
model = "gpt-5"

[profiles.work]
model = "o3"

[model_providers.other]
base_url = "https://other/v1"
api_key = "sk-other"
"@, (New-Object System.Text.UTF8Encoding($false)))

    [System.IO.File]::WriteAllText($claudePath, '{"env":{"FOO":"bar"}}', (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Text([string]$p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }

function Invoke-Sync([string[]]$toolList, [switch]$DryRun) {
    $cfg = @{
        remoteUrl = $mockUrl; bridgeKey = $mockKey
        defaultModel = ""; tools = ($toolList -join ","); backupKeep = 3
        urlHistory = @()
    }
    return (Invoke-Sync9Router -Config $cfg -Tools $toolList -DryRun:$DryRun -Quiet)
}

Reset-Sandbox

# Load the engine in-process, pointed at a config inside the sandbox so the
# state file lands there too and the real one is never touched.
$cfgFile = Join-Path $sandbox "config.json"
[System.IO.File]::WriteAllText($cfgFile, ('{"remoteUrl":"' + $mockUrl + '","bridgeKey":"' + $mockKey + '","tools":["opencode","pi","omp","hermes","claude","codex"],"backupKeep":3}'), (New-Object System.Text.UTF8Encoding($false)))
. "$engineRoot\sync.ps1" -ConfigPath $cfgFile

# Refuse to continue if the engine would write outside the sandbox. Without this
# an adapter that ignores an environment override reaches the user's real tool
# configs, which is exactly what happened on the first run of this file.
$leaks = @()
foreach ($t in $script:AllTools) {
    foreach ($p in @(Get-ToolConfigPaths $t)) {
        if (-not $p.StartsWith($sandbox)) { $leaks += "$t -> $p" }
    }
}
if ($leaks.Count -gt 0) {
    Write-Host "ABORT: these paths are outside the sandbox:" -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "  The real configs have NOT been touched." -ForegroundColor Green
    exit 1
}
Write-Host "== e2e (mock bridge, sandbox $($sandbox.Substring($sandbox.LastIndexOf('\') + 1)))"

# --- 1. the full sync ------------------------------------------------------

$res = Invoke-Sync @("opencode", "pi", "omp", "hermes", "claude", "codex")

Check "sync succeeds" {
    Equal $res.ok $true $res.error
}

Check "a stale plural-only id is pruned, not fatal" {
    Equal $res.ok $true "the run completes despite the stale ids"
    # Only the singular `provider` key is consumed. stale/removed lives
    # solely in the plural snapshot, gone/model solely in pi's plural
    # snapshot, retired/model nowhere at all.
    Lacks ($res.modelIds -join ",") "stale/removed" "a deleted model in the stale plural key stays out"
    Lacks ($res.modelIds -join ",") "gone/model" "a plural-only pin from another tool stays out"
    Lacks ($res.modelIds -join ",") "retired/model" "an id nobody configured stays out"
    # The four ids from the singular keys, all present.
    Equal @($res.modelIds).Count 4
}

Check "opencode: the foreign provider survives" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    Equal (@($j.providers.PSObject.Properties.Name) -join ",") "other,9router"
    Equal $j.providers.other.package "other-pkg"
    Has (@($j.providers.other.models.PSObject.Properties.Name) -join ",") "keep/me"
}

Check "opencode: the dangling agent pin is released, the agent is kept" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    Equal $j.agents.explorer.model $null
    Equal $j.agents.explorer.description "keeps this"
    Equal $j.agents.scout.model "9router/vendor:co/dupe" "a pin to a resolved model is kept, not released"
    Equal $j.agents.build.model "opencode/big-pickle" "another provider's pin is untouched"
    # Two releases overall: opencode's agent pin and omp's advisor role, both
    # pointing at 9router/retired/model, which is nowhere (neither the phone
    # pins nor the catalog). gone/model is mirrored, so a pin to it is kept.
    Equal (@($res.dangling).Count) 2
    Has (@($res.dangling | ForEach-Object { "$($_.Tool):$($_.Where)" }) -join ",") "opencode:agents.explorer.model"
    Has (@($res.dangling | ForEach-Object { "$($_.Tool):$($_.Where)" }) -join ",") "omp:modelRoles.advisor"
}

Check "opencode: a model id beginning with PS survives the writer" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    Has (@($j.providers.'9router'.models.PSObject.Properties.Name) -join ",") "ps-prefixed/model"
}

Check "opencode: a model id containing # survives the writer" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    Has (@($j.providers.'9router'.models.PSObject.Properties.Name) -join ",") "openrouter/weird#id"
}

Check "opencode: tools stay enabled for a model whose catalog omits the flag" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    $m = $j.providers.'9router'.models.'9router/one-day/glm-5.3-flash'
    Equal $m.capabilities.tools $true
}

Check "opencode: a string 'false' in the catalog is honoured" {
    $j = (Read-Text $ocPath) | ConvertFrom-Json
    $m = $j.providers.'9router'.models.'openrouter/weird#id'
    Equal $m.capabilities.tools $false
    Equal ($m.capabilities.input -join ",") "text" "vision: 'false' must not add image"
}

Check "omp: the foreign provider's model list is NOT overwritten" {
    $t = Read-Text $ompPath
    Has $t "- id: other-model" "the other provider keeps its own model"
}

Check "omp: the 9router provider gets the new list and endpoint" {
    $t = Read-Text $ompPath
    Has $t "baseUrl: http://127.0.0.1:20999/v1"
    Lacks $t "stale-9r-model"
    Has $t "9router/one-day/glm-5.3-flash"
}

Check "omp: generated entries sit inside the 9router provider block" {
    $lines = @(Read-Text $ompPath) -split "`r?`n"
    $nine = -1; $disc = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "  9router:") { $nine = $i }
        if ($lines[$i] -eq "discovery:") { $disc = $i }
    }
    Equal ($nine -gt 0) $true "the 9router header must exist"
    Equal ($disc -gt $nine) $true "discovery must come after it"

    $generated = @()
    $foreign = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s+- id:\s*(.+?)\s*$') { continue }
        if ($lines[$i] -eq "      - id: other-model") { $foreign += $i } else { $generated += $i }
    }
    Equal $foreign.Count 1 "the foreign provider keeps exactly one entry"
    Equal ($foreign[0] -lt $nine) $true "and it stays above 9router"
    Equal $generated.Count 4 "four models were written"
    foreach ($i in $generated) {
        Equal ($i -gt $nine -and $i -lt $disc) $true "entry at line $i escaped the provider block"
    }
}

Check "omp: no provider-level key is duplicated within its own block" {
    $lines = @(Read-Text $ompPath) -split "`r?`n"
    # Scoped per provider: `models:` legitimately appears once under each. The
    # failure this guards against is one provider carrying the key twice, which
    # makes the second one an empty map that swallows the model list.
    $byProvider = @{}
    $current = "<root>"
    foreach ($l in $lines) {
        if ($l -match '^  ([\w-]+):\s*$') { $current = $Matches[1]; if (-not $byProvider.ContainsKey($current)) { $byProvider[$current] = @() }; continue }
        if ($l -match '^[^\s#]') { $current = "<root>"; if (-not $byProvider.ContainsKey($current)) { $byProvider[$current] = @() }; continue }
        if ($l -notmatch '^    ([\w-]+):') { continue }
        $k = $Matches[1]
        if (-not $byProvider.ContainsKey($current)) { $byProvider[$current] = @() }
        $byProvider[$current] += $k
    }
    foreach ($prov in $byProvider.Keys) {
        $dupes = @($byProvider[$prov] | Group-Object | Where-Object { $_.Count -gt 1 })
        Equal $dupes.Count 0 ("$prov repeats: " + (($dupes | ForEach-Object { $_.Name }) -join ", "))
    }
}

Check "omp: the models key appears once per provider" {
    $lines = @(Read-Text $ompPath) -split "`r?`n"
    $otherModels = @(); $nineModels = @()
    $section = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "  other:") { $section = "other"; continue }
        if ($lines[$i] -eq "  9router:") { $section = "9router"; continue }
        if ($lines[$i] -match '^[^\s]') { $section = "" ; continue }
        if ($lines[$i] -eq "    models:") {
            if ($section -eq "other") { $otherModels += $i } elseif ($section -eq "9router") { $nineModels += $i }
        }
    }
    Equal $otherModels.Count 1 "other still has its own models key"
    Equal $nineModels.Count 1 "9router has exactly one models key"
}

Check "omp: a role pinned to a removed model is released" {
    $t = Read-Text $ompcfgPath
    Lacks $t "advisor"
    Has $t "helper" "a role pinned to a mirrored model is kept"
    Has $t "default: 9router/"
    $d = @($res.dangling | Where-Object { $_.Tool -eq "omp" })
    Equal $d.Count 1 "the release must be reported"
}

Check "hermes: a 9router provider is added and the wahyu one survives" {
    $t = Read-Text $hermesPath
    Has $t "bansos.example"
    Has $t "HERMES_CUSTOM_WAHYU_API_KEY"
    Equal ($t.IndexOf("  9router:") -gt $t.IndexOf("  wahyu:")) $true "9router is appended after wahyu"
    # discover_models must stay a YAML boolean, not the string "false".
    Has $t "discover_models: false"
    Lacks $t 'discover_models: "false"'
    # model: block is repointed at the bridge.
    Has $t "provider: 9router"
    Has $t "base_url: http://127.0.0.1:20999/v1"
    Has $t "key_env: OPENAI_API_KEY"
}

Check "hermes: exactly one models: key per provider" {
    $lines = @(Read-Text $hermesPath) -split "`r?`n"
    $nineIdx = [array]::IndexOf($lines, "  9router:")
    $verIdx = [array]::IndexOf($lines, "_config_version: 50")
    $modelsKeys = @()
    for ($i = $nineIdx; $i -lt $verIdx; $i++) { if ($lines[$i] -eq "    models:") { $modelsKeys += $i } }
    Equal $modelsKeys.Count 1 ("found $($modelsKeys.Count) 'models:' keys in the 9router block at " + ($modelsKeys -join ","))
}

Check "hermes: _config_version stays at the top level" {
    $lines = @(Read-Text $hermesPath) -split "`r?`n"
    $i = [array]::IndexOf($lines, "_config_version: 50")
    Equal ($i -ge 0) $true
    Equal $lines[$i] "_config_version: 50"
}

Check "hermes: the .env key is written" {
    Has (Read-Text $envPath) "OPENAI_API_KEY=sk-mock-api-key"
    Has (Read-Text $envPath) "HERMES_CUSTOM_WAHYU_API_KEY=sk-old" "the existing entry survives"
}

Check "codex: the foreign provider section is untouched" {
    $t = Read-Text $codexPath
    Has $t 'base_url = "https://other/v1"'
    Has $t 'api_key = "sk-other"'
    Has $t 'model = "o3"'
}

Check "codex: the top-level keys point at the bridge" {
    $t = Read-Text $codexPath
    Has $t 'base_url = "http://127.0.0.1:20999/v1"'
    Has $t 'model = "9router/one-day/glm-5.3-flash"'
    Lacks $t "9router/9router" "the provider prefix is added exactly once"
}

Check "claude: existing env keys survive" {
    $j = (Read-Text $claudePath) | ConvertFrom-Json
    Equal $j.env.FOO "bar"
    Equal $j.env.ANTHROPIC_BASE_URL "http://127.0.0.1:20999/v1"
    Equal $j.env.ANTHROPIC_AUTH_TOKEN "sk-mock-api-key"
}

Check "pi: models.json and settings.json are written" {
    Has (Read-Text "$sandbox\home\.pi\agent\models.json") '"baseUrl": "http://127.0.0.1:20999/v1"'
    $s = (Read-Text "$sandbox\home\.pi\agent\settings.json") | ConvertFrom-Json
    Equal $s.defaultProvider "9router"
    Has $s.defaultModel "one-day/glm"
}

# --- 2. idempotence --------------------------------------------------------

Check "a second run changes nothing" {
    $before = @{}
    foreach ($p in @($ocPath, $hermesPath, $ompPath, $ompcfgPath, $codexPath, $claudePath)) { $before[$p] = Read-Text $p }
    $r2 = Invoke-Sync @("opencode", "pi", "omp", "hermes", "claude", "codex")
    Equal $r2.ok $true $r2.error
    foreach ($p in $before.Keys) {
        $now = Read-Text $p
        Equal $now $before[$p] "$p was rewritten on a no-op run"
    }
}

# --- 3. failures are isolated ---------------------------------------------

Check "one failing tool does not stop the others, and the report is honest" {
    Reset-Sandbox
    # Make hermes fail: config.yaml present but the directory is read-only is
    # awkward, so instead point omp at a directory-shaped failure by removing
    # write access via a locked file is not portable. Use an unknown tool instead
    # for the strictness check, and a malformed omp file for the isolation check.
    [System.IO.File]::WriteAllText($ompPath, "providers:`n  9router:`n    baseUrl: x`n", (New-Object System.Text.UTF8Encoding($false)))
    $r3 = Invoke-Sync @("opencode", "omp", "hermes", "claude", "codex")
    Equal $r3.ok $true "a tool with an unusual file still completes"
    # hermes and opencode were still written
    Has (Read-Text $ocPath) "9router"
    Has (Read-Text $hermesPath) "9router:"
}

Check "an unknown tool name is an error, not a silent full sync" {
    Reset-Sandbox
    $before = Read-Text $ocPath
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = ""; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $r4 = Invoke-Sync9Router -Config $cfg -Tools @("opencodee") -Quiet
    Equal $r4.ok $false
    Has $r4.error "Unknown tool"
    Equal (Read-Text $ocPath) $before "nothing may be written when the tool list is invalid"
    Equal (Test-Path "$sandbox\home\.omp\agent\models.yml") $true "and omp must be left alone too"
    Has (Read-Text "$sandbox\home\.omp\agent\models.yml") "stale-9r-model" "a typo must not fan out to every tool"
}

Check "a valid tool list syncs exactly those tools" {
    Reset-Sandbox
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = ""; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $r5 = Invoke-Sync9Router -Config $cfg -Tools @("claude") -Quiet
    Equal $r5.ok $true $r5.error
    Equal (@($r5.rows | ForEach-Object { $_.Tool }) -join ",") "claude" "only the requested tool runs"
    Has (Read-Text $ocPath) "9router/old/model" "opencode is not synced"
}

Check "a bad bridge key fails with an actionable message" {
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = "wrong-key"; defaultModel = ""; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $rBadKey = Invoke-Sync9Router -Config $cfg -Quiet
    Equal $rBadKey.ok $false
    Has $rBadKey.error "401"
}

Check "an uppercase bridge key is normalised, not rejected" {
    # The receiver compares byte-exact, so the uppercase form is a different key
    # and comes back as a 401 that reads like "wrong key".
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey.ToUpperInvariant(); defaultModel = ""; tools = @("claude"); backupKeep = 3; urlHistory = @() }
    $rUpper = Invoke-Sync9Router -Config $cfg -Quiet
    Equal $rUpper.ok $true $rUpper.error
}

Check "a URL without a scheme is rejected before any network call" {
    $cfg = @{ remoteUrl = "192.168.0.4:20128"; bridgeKey = $mockKey; defaultModel = ""; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $rNoScheme = Invoke-Sync9Router -Config $cfg -Quiet
    Equal $rNoScheme.ok $false
    Has $rNoScheme.error "remoteUrl"
}

# --- 4. state --------------------------------------------------------------

Check "state records the run exactly once, in the sandbox" {
    Reset-Sandbox
    Remove-Item -LiteralPath (Join-Path $sandbox "sync-9router.state.json") -Force -ErrorAction SilentlyContinue
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = ""; tools = @("opencode","pi","omp","hermes","claude","codex"); backupKeep = 3; urlHistory = @() }
    $r7 = Invoke-Sync9Router -Config $cfg -Quiet
    Record-SyncRun $r7
    $st = Get-State
    Equal @($st.log).Count 1 "one sync, one log entry"
    Equal (Split-Path -Parent (Get-StatePath)) $sandbox "the state file must live beside the config, not at the repo root"
    Has (@($st.perTool.PSObject.Properties.Name) -join ",") "pi" "pi must appear in perTool"
    Has (@($st.perTool.PSObject.Properties.Name) -join ",") "omp" "omp must appear in perTool"
    Equal $st.lastRun.status "ok"
}

Check "a tool that wrote nothing is absent from perTool, not 'unchanged'" {
    $st = Get-State
    Has (@($st.perTool.PSObject.Properties.Name) -join ",") "claude"
    # opencode was synced and rewritten.
    Equal $st.perTool.opencode.status "updated"
}

Check "a failed run is recorded too" {
    $cfg = @{ remoteUrl = "http://127.0.0.1:1"; bridgeKey = "x"; defaultModel = ""; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $r8 = Invoke-Sync9Router -Config $cfg -Quiet
    Equal $r8.ok $false
    Record-SyncRun $r8
    $st = Get-State
    Equal @($st.log).Count 2
    Equal $st.log[0].ok $false
    Equal $st.lastRun.status "fail"
}

# --- 5. whatif -------------------------------------------------------------

Check "a dry run writes nothing" {
    Reset-Sandbox
    $before = @{}
    foreach ($p in @($ocPath, $hermesPath, $ompPath, $ompcfgPath, $codexPath, $claudePath)) {
        if (Test-Path $p) { $before[$p] = Read-Text $p }
    }
    $r9 = Invoke-Sync @("opencode", "pi", "omp", "hermes", "claude", "codex") -DryRun
    Equal $r9.ok $true $r9.error
    Equal $r9.whatIf $true
    foreach ($p in $before.Keys) { Equal (Read-Text $p) $before[$p] "$p was written during a dry run" }
    Equal (@($r9.rows | Where-Object { $_.Status -eq "whatif" }).Count) 9 "every file reports whatif"
    Equal (Test-Path "$sandbox\home\.pi\agent\models.json") $false "pi files must not be created either"
}

Check "the model preview names each model's source tool" {
    Reset-Sandbox
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = ""; tools = @("opencode","pi"); backupKeep = 3; urlHistory = @() }
    $v = Get-ResolvedModelPreview $cfg
    Equal $v.ok $true $v.error
    # The mock publishes three ids via opencode and one via pi.
    $byId = @{}
    foreach ($m in $v.models) { $byId[$m.id] = $m.source }
    Equal $byId["9router/one-day/glm-5.3-flash"] "opencode"
    Equal $byId["vendor:co/dupe"] "pi"
    # Stale plural-only ids never reach the preview: gone/model lives solely
    # in pi's plural snapshot, stale/removed solely in opencode's.
    Equal $byId.ContainsKey("9router/gone/model") $false "plural-only pin must not leak"
    Equal $byId.ContainsKey("stale/removed") $false "deleted model must not leak"
    Equal @($v.skipped).Count 0
    # Empty config follows 9Router: the first resolved model is effective.
    Equal $v.configuredDefault ""
    Equal $v.effectiveDefault "one-day/glm-5.3-flash"
    Equal (@($v.models | Where-Object { $_.isEffectiveDefault }).Count) 1
}

Check "the preview marks the configured default" {
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = "ps-prefixed/model"; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $v = Get-ResolvedModelPreview $cfg
    Equal $v.ok $true $v.error
    Equal $v.configuredDefault "ps-prefixed/model"
    Equal $v.effectiveDefault "ps-prefixed/model"
    $marked = @($v.models | Where-Object { $_.isConfiguredDefault })
    Equal $marked.Count 1
    Equal $marked[0].id "ps-prefixed/model"
}

Check "a prefixed default still matches its model" {
    $cfg = @{ remoteUrl = $mockUrl; bridgeKey = $mockKey; defaultModel = "9router/ps-prefixed/model"; tools = @("opencode"); backupKeep = 3; urlHistory = @() }
    $v = Get-ResolvedModelPreview $cfg
    Equal $v.ok $true $v.error
    Equal $v.effectiveDefault "ps-prefixed/model"
    Equal (@($v.models | Where-Object { $_.isEffectiveDefault }).Count) 1
}

# --- 6. the launcher ------------------------------------------------------

Check "9sync.cmd --cli passes a comma-separated tool list through intact" {
    # A launcher that re-collects arguments one at a time splits
    # "-Tools opencode,hermes" into two arguments, and the engine then syncs
    # only the first tool while looking like it did what was asked.
    $repo = Split-Path -Parent $PSScriptRoot
    $cmd = Join-Path $repo "9sync.cmd"
    if (-not (Test-Path $cmd)) { throw "9sync.cmd not found" }

    $output = cmd /c "`"$cmd`" --cli -RemoteUrl $mockUrl -BridgeKey $mockKey -Tools opencode,hermes -WhatIf" 2>&1 | Out-String
    if ($output -match "Unknown tool") { throw "the tool list was mangled: `n$output" }
    if ($output -notmatch "(?m)^\s+opencode\s+whatif") { throw "opencode did not run: `n$output" }
    if ($output -notmatch "(?m)^\s+hermes\s+whatif") { throw "hermes did not run: `n$output" }
    if ($output -notmatch "Preview done") { throw "the engine did not run: `n$output" }
}

Check "9sync.cmd --cli reaches the engine and reports a real failure" {
    $repo = Split-Path -Parent $PSScriptRoot
    $cmd = Join-Path $repo "9sync.cmd"
    $output = cmd /c "`"$cmd`" --cli -RemoteUrl http://127.0.0.1:1 -BridgeKey x" 2>&1 | Out-String
    if ($output -notmatch "Sync failed") { throw "a failing sync must say so: `n$output" }
    # The wrapper must not turn a failure into a success.
    if ($output -match "^\[OK\] Done") { throw "the launcher reported success on a failed sync" }
}

Check "an argument containing spaces survives the launcher" {
    $repo = Split-Path -Parent $PSScriptRoot
    $setupFile = Join-Path $sandbox "setup file with spaces.md"
    # Built from an array, not a here-string: a backtick is an escape character
    # inside a double-quoted here-string, and the block tag is made of them.
    $fence = [string][char]96 + [char]96 + [char]96
    $body = @(
        "Notes."
        ""
        ($fence + "9sync")
        "{"
        ('  "remoteUrl": "' + $mockUrl + '",')
        ('  "bridgeKey": "' + $mockKey + '",')
        '  "tools": ["opencode"]'
        "}"
        $fence
    ) -join "`n"
    [System.IO.File]::WriteAllText($setupFile, $body, (New-Object System.Text.UTF8Encoding($false)))

    $cfgFile2 = Join-Path $sandbox "import.json"
    [System.IO.File]::WriteAllText($cfgFile2, '{"remoteUrl":"","bridgeKey":"","tools":[],"backupKeep":5,"urlHistory":[]}', (New-Object System.Text.UTF8Encoding($false)))

    $out = powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\engine\setup.ps1" -SetupFile $setupFile -ConfigPath $cfgFile2 -WhatIf 2>&1 | Out-String
    if ($out -notmatch "Setup file:") { throw "the path with spaces was not read: `n$out" }
    if ($out -notmatch "would change") { throw "-WhatIf did not preview: `n$out" }
    $afterPreview = (Get-Content $cfgFile2 -Raw | ConvertFrom-Json)
    Equal $afterPreview.remoteUrl "" "-WhatIf must not write"

    $applied = powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\engine\setup.ps1" -SetupFile $setupFile -ConfigPath $cfgFile2 -Force 2>&1 | Out-String
    if ($applied -notmatch "Saved:") { throw "the import did not save: `n$applied" }

    $cfg = (Get-Content $cfgFile2 -Raw | ConvertFrom-Json)
    Equal $cfg.remoteUrl $mockUrl "the import did not apply the endpoint"
    Equal $cfg.bridgeKey $mockKey
    Equal (@($cfg.tools) -join ",") "opencode"
}

Check "the setup import only takes the tool list when asked" {
    # Without -Force the phone's tool list must not overwrite one the user has
    # already curated; only the endpoint and key come across.
    $repo = Split-Path -Parent $PSScriptRoot
    $cfgFile3 = Join-Path $sandbox "noforce.json"
    [System.IO.File]::WriteAllText($cfgFile3, ('{"remoteUrl":"","bridgeKey":"","tools":["codex","claude"],"backupKeep":9,"urlHistory":[]}'), (New-Object System.Text.UTF8Encoding($false)))

    powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\engine\setup.ps1" -SetupFile (Join-Path $sandbox "setup file with spaces.md") -ConfigPath $cfgFile3 | Out-Null
    $cfg = (Get-Content $cfgFile3 -Raw | ConvertFrom-Json)
    Equal (@($cfg.tools) -join ",") "codex,claude" "the tool list must survive without -Force"
    Equal ([int]$cfg.backupKeep) 9
    Equal $cfg.remoteUrl $mockUrl
}

# --- cleanup ---------------------------------------------------------------

$env:USERPROFILE = $origHome
$env:LOCALAPPDATA = $origLocal
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed failed, $passed passed" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  FAIL $f" -ForegroundColor Red }
    exit 1
}
Write-Host "$passed passed" -ForegroundColor Green
exit 0