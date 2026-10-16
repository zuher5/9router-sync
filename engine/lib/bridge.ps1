<#
    bridge.ps1 - talking to 9Router.

    Split out from the monolith so the tests can exercise model resolution and
    catalog capability handling without any network at all.
#>

$script:BaseUrl = ""
$script:ApiBase = ""
$script:ApiKey  = ""

function Set-Endpoint([string]$remoteUrl, [string]$bridgeKey) {
    $script:BaseUrl = "$remoteUrl".Trim().TrimEnd("/")
    $script:ApiBase = "$script:BaseUrl/v1"
    $script:BridgeKey = $bridgeKey
}

function Get-BridgeHeaders {
    return @{
        "x-9r-bridge-key"            = $script:BridgeKey.Trim()
        "ngrok-skip-browser-warning" = "true"
        "Accept"                     = "application/json"
    }
}

function Get-BridgeJson([string]$path) {
    $uri = "$script:BaseUrl/api/bridge/$path"
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers (Get-BridgeHeaders) -UseBasicParsing -TimeoutSec 25
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 401) { throw "Bridge key rejected (401) on $path. The key is 64 hex characters from the phone - check for a trailing space or a pasted API key (sk-...)." }
        if ($code -eq 403) { throw "Access denied (403) on $path." }
        if ($code -eq 404) { throw "No bridge at $script:BaseUrl (404). If this used to be a tunnel URL, it has rotated - set the new endpoint in Settings." }
        throw "Could not reach the bridge ($path): $($_.Exception.Message)"
    }

    $body = [string]$resp.Content
    # ngrok answers clients that omit the bypass header with an HTML
    # interstitial, which would otherwise parse as a successful sync.
    if ($body -match 'ERR_NGROK') {
        throw "ngrok blocked $path (ERR_NGROK interstitial)."
    }
    if ($body.TrimStart() -notmatch '^\{') {
        $head = $body.Substring(0, [Math]::Min(60, $body.Length))
        throw "Response from $path is not JSON (got $($body.Length) bytes, starting with '$head')."
    }
    try { return ($body | ConvertFrom-Json) }
    catch { throw "Could not parse JSON from ${path}: $($_.Exception.Message)" }
}

# Reachability probe that reports instead of throwing, so one dead candidate URL
# does not abort a sweep of the others.
function Test-BridgeUrl([string]$url, [string]$bridgeKey, [int]$timeoutSec = 8) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri "$($url.TrimEnd('/'))/api/bridge/keys" `
            -Headers @{ "x-9r-bridge-key" = $bridgeKey.Trim(); "ngrok-skip-browser-warning" = "true" } `
            -UseBasicParsing -TimeoutSec $timeoutSec
        $sw.Stop()
        $body = [string]$r.Content
        $note = if ($body -match 'ERR_NGROK') { "ngrok interstitial" }
                elseif ($body.TrimStart() -notmatch '^\{') { "not JSON ($($body.Length)B)" }
                else { "auth ok" }
        $ok = $note -eq "auth ok"
        return [pscustomobject]@{ Url = $url; Ok = $ok; Code = [int]$r.StatusCode; Ms = $sw.ElapsedMilliseconds; Note = $note }
    } catch {
        $sw.Stop()
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $note = if ($code) { "HTTP $code" } else { $_.Exception.Message.Split([Environment]::NewLine)[0] }
        return [pscustomobject]@{ Url = $url; Ok = $false; Code = $code; Ms = $sw.ElapsedMilliseconds; Note = $note }
    }
}

function Get-ActiveApiKey {
    $keys = Get-BridgeJson "keys"
    foreach ($k in @($keys.keys)) {
        if ($k.isActive -and $k.key) { return "$($k.key)" }
    }
    return ""
}

function Get-ModelCatalog {
    $headers = @{
        "Authorization"              = "Bearer $script:ApiKey"
        "ngrok-skip-browser-warning" = "true"
    }
    try {
        $resp = Invoke-WebRequest -Uri "$script:ApiBase/models" -Headers $headers -UseBasicParsing -TimeoutSec 30
    } catch {
        throw "Could not fetch the model catalog: $($_.Exception.Message)"
    }
    $body = [string]$resp.Content
    # Same interstitial guard as the bridge path. Without it an HTML error page
    # surfaces as "unexpected character while parsing value: <".
    if ($body -match 'ERR_NGROK') { throw "ngrok blocked the catalog request (ERR_NGROK)." }
    try {
        $parsed = $body | ConvertFrom-Json
    } catch {
        throw "The catalog response is not JSON: $($_.Exception.Message)"
    }
    $data = @($parsed.data | Where-Object { $_ })
    if ($data.Count -eq 0) { throw "The catalog came back empty." }
    return $data
}

function Connect-Bridge {
    $script:ApiKey = ""
    $script:ApiKey = Get-ActiveApiKey
    if (-not $script:ApiKey) { throw "No active API key on the bridge (/keys is empty)." }
}

# One cheap completion. This is how a provider that has run out of credit shows
# up before it is picked up in a real conversation.
function Test-ModelLive([string]$modelId, [int]$timeoutSec = 25) {
    $headers = @{
        "Authorization"              = "Bearer $script:ApiKey"
        "ngrok-skip-browser-warning" = "true"
    }
    $body = @{
        model = $modelId
        messages = @(@{ role = "user"; content = "reply with the single word: ok" })
        max_tokens = 8
        stream = $false
    } | ConvertTo-Json -Depth 6

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$script:ApiBase/chat/completions" -Headers $headers `
            -Method Post -Body $body -ContentType "application/json" -TimeoutSec $timeoutSec
        $sw.Stop()
        if ($r.error) {
            return [pscustomobject]@{ Model = $modelId; Ok = $false; Code = 0; Ms = $sw.ElapsedMilliseconds; Note = "$($r.error.message)" }
        }
        return [pscustomobject]@{ Model = $modelId; Ok = $true; Code = 200; Ms = $sw.ElapsedMilliseconds; Note = "ok" }
    } catch {
        $sw.Stop()
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $note = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $d = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($d.error -and $d.error.message) { $note = $d.error.message }
            } catch { $note = $null }
        }
        if (-not $note) { $note = if ($code) { "HTTP $code" } else { $_.Exception.Message.Split([Environment]::NewLine)[0] } }
        return [pscustomobject]@{ Model = $modelId; Ok = $false; Code = $code; Ms = $sw.ElapsedMilliseconds; Note = $note }
    }
}