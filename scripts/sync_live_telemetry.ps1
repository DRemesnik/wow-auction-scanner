param(
  [string]$SavedVarsPath = "D:\Games\World of Warcraft\_forever_\WTF\Account\121011797#1\SavedVariables\ForeverSniper.lua",
  [string]$RepoRoot = "d:\Antigravity\wow-auction-scanner\wow-auction-scanner",
  [switch]$Watch,
  [switch]$NoPush,
  [int]$PollSeconds = 10
)

$ErrorActionPreference = "Stop"

function Extract-LuaBlock([string]$text, [string]$keyName) {
  $marker = '["' + $keyName + '"] = {'
  $start = $text.IndexOf($marker)
  if ($start -lt 0) { return "" }
  $braceStart = $text.IndexOf('{', $start)
  $depth = 0
  for ($i = $braceStart; $i -lt $text.Length; $i++) {
    $ch = $text[$i]
    if ($ch -eq '{') { $depth++ }
    elseif ($ch -eq '}') {
      $depth--
      if ($depth -eq 0) {
        return $text.Substring($braceStart + 1, $i - $braceStart - 1)
      }
    }
  }
  return ""
}

function Parse-NumericKeyRecords([string]$block) {
  $map = @{}
  if ([string]::IsNullOrWhiteSpace($block)) { return $map }
  $rxEntry = [regex]'\[(\d+)\]\s*=\s*\{([^{}]*)\}'
  foreach ($m in $rxEntry.Matches($block)) {
    $id = $m.Groups[1].Value
    $body = $m.Groups[2].Value
    $rec = @{}
    foreach ($kv in ([regex]'\["([^"]+)"\]\s*=\s*("([^"]*)"|[-+]?\d+(?:\.\d+)?)').Matches($body)) {
      $k = $kv.Groups[1].Value
      if ($kv.Groups[3].Success) {
        $rec[$k] = $kv.Groups[3].Value
      } else {
        $numTxt = $kv.Groups[2].Value
        if ($numTxt.Contains('.')) { $rec[$k] = [double]$numTxt }
        else { $rec[$k] = [int64]$numTxt }
      }
    }
    $map[$id] = $rec
  }
  return $map
}

function Parse-StringKeyRecords([string]$block) {
  $map = @{}
  if ([string]::IsNullOrWhiteSpace($block)) { return $map }
  $rxEntry = [regex]'\["([^"]+)"\]\s*=\s*\{([^{}]*)\}'
  foreach ($m in $rxEntry.Matches($block)) {
    $key = $m.Groups[1].Value
    $body = $m.Groups[2].Value
    $rec = @{}
    foreach ($kv in ([regex]'\["([^"]+)"\]\s*=\s*("([^"]*)"|[-+]?\d+(?:\.\d+)?)').Matches($body)) {
      $k = $kv.Groups[1].Value
      if ($kv.Groups[3].Success) {
        $rec[$k] = $kv.Groups[3].Value
      } else {
        $numTxt = $kv.Groups[2].Value
        if ($numTxt.Contains('.')) { $rec[$k] = [double]$numTxt }
        else { $rec[$k] = [int64]$numTxt }
      }
    }
    $map[$key] = $rec
  }
  return $map
}

function Build-LiveTelemetry([string]$svPath) {
  if (-not (Test-Path $svPath)) {
    throw "SavedVariables file not found: $svPath"
  }
  $txt = [System.IO.File]::ReadAllText($svPath, [System.Text.Encoding]::UTF8)

  $marketBlock = Extract-LuaBlock $txt "market"
  $marketRecs = Parse-NumericKeyRecords $marketBlock

  $telBlock = Extract-LuaBlock $txt "telemetry"
  $telItemsBlock = Extract-LuaBlock $telBlock "items"
  $telRecs = Parse-NumericKeyRecords $telItemsBlock

  $salesBlock = Extract-LuaBlock $txt "sales"
  $salesByItemBlock = Extract-LuaBlock $salesBlock "byItem"
  $salesRecs = Parse-StringKeyRecords $salesByItemBlock

  # Merge anonymized per-item telemetry (zero character names, zero personal gold)
  $items = @{}
  $allIds = New-Object System.Collections.Generic.HashSet[string]
  foreach ($k in $marketRecs.Keys) { [void]$allIds.Add($k) }
  foreach ($k in $telRecs.Keys) { [void]$allIds.Add($k) }

  foreach ($id in $allIds) {
    $out = @{}
    if ($marketRecs.ContainsKey($id)) {
      $m = $marketRecs[$id]
      if ($m.ContainsKey("p1")) { $out["p1"] = [int64]$m["p1"] }
      if ($m.ContainsKey("p2")) { $out["p2"] = [int64]$m["p2"] }
      if ($m.ContainsKey("wallQty")) { $out["wallQty"] = [int64]$m["wallQty"] }
      if ($m.ContainsKey("totalDepth")) { $out["totalDepth"] = [int64]$m["totalDepth"] }
      if ($m.ContainsKey("spreadPct")) { $out["spreadPct"] = [math]::Round([double]$m["spreadPct"], 1) }
      if ($m.ContainsKey("vDrain")) { $out["vDrain"] = [math]::Round([double]$m["vDrain"], 1) }
      if ($m.ContainsKey("cls")) { $out["cls"] = [int]$m["cls"] }
      if ($m.ContainsKey("scans")) { $out["scans"] = [int]$m["scans"] }
      if ($m.ContainsKey("updatedAt")) { $out["updatedAt"] = [int64]$m["updatedAt"] }
    }
    if ($telRecs.ContainsKey($id)) {
      $t = $telRecs[$id]
      $buys = if ($t.ContainsKey("buys")) { [int]$t["buys"] } else { 0 }
      $missed = if ($t.ContainsKey("missed")) { [int]$t["missed"] } else { 0 }
      $dips = if ($t.ContainsKey("dips")) { [int]$t["dips"] } else { 0 }
      $scanCnt = if ($t.ContainsKey("scanCnt")) { [int]$t["scanCnt"] } else { 0 }
      $scanSum = if ($t.ContainsKey("scanSum")) { [int64]$t["scanSum"] } else { 0 }
      if ($dips -gt 0) { $out["dips"] = $dips }
      if (($buys + $missed) -gt 0) {
        $out["winRate"] = [math]::Round(($buys * 100.0) / ($buys + $missed), 1)
        $out["attempts"] = $buys + $missed
      }
      if ($scanCnt -gt 0 -and $scanSum -gt 0) {
        $out["avgFloor"] = [int64][math]::Floor($scanSum / $scanCnt)
      }
    }
    if ($out.Count -gt 0) {
      $items[$id] = $out
    }
  }

  # Anonymized confirmed sales by item name (from mailbox invoices)
  $salesByName = @{}
  foreach ($nm in $salesRecs.Keys) {
    $sr = $salesRecs[$nm]
    $qty = if ($sr.ContainsKey("qty")) { [int64]$sr["qty"] } else { 0 }
    $net = if ($sr.ContainsKey("net")) { [int64]$sr["net"] } else { 0 }
    $deals = if ($sr.ContainsKey("deals")) { [int]$sr["deals"] } else { 0 }
    if ($qty -gt 0 -and $net -gt 0) {
      $salesByName[$nm] = @{
        avgSellNet = [int64][math]::Floor($net / $qty)
        qty        = $qty
        deals      = $deals
      }
    }
  }

  $nowUtc = [DateTime]::UtcNow
  $epoch = [int64](($nowUtc - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds)
  return @{
    version      = 1
    source       = "ForeverSniper"
    updated_at   = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    updated_ts   = $epoch
    items_count  = $items.Count
    sales_count  = $salesByName.Count
    items        = $items
    salesByName  = $salesByName
  }
}

function Invoke-Git([string[]]$GitArgs, [switch]$IgnoreError) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  if (-not $IgnoreError -and $code -ne 0) {
    throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join " "), $code, ($out -join "`n"))
  }
  return $out
}

function Sync-Once {
  $payload = Build-LiveTelemetry $SavedVarsPath
  $json = $payload | ConvertTo-Json -Depth 5 -Compress
  $localOut = Join-Path $RepoRoot "data\live_telemetry.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($localOut, $json, $utf8NoBom)
  Write-Host ("[{0}] Built live_telemetry.json: {1} items, {2} confirmed sales ({3} bytes)" -f (Get-Date -Format "HH:mm:ss"), $payload.items_count, $payload.sales_count, $json.Length)

  if ($NoPush) { return }

  # Push ONLY live_telemetry.json to gh-pages using an isolated temporary worktree (zero conflict with master or scan.yml)
  $wtDir = Join-Path $env:TEMP "wow_ah_ghpages_live_sync"
  Push-Location $RepoRoot
  try {
    Invoke-Git @("worktree", "remove", "--force", $wtDir) -IgnoreError | Out-Null
    Invoke-Git @("worktree", "prune") -IgnoreError | Out-Null
    if (Test-Path $wtDir) { Remove-Item $wtDir -Recurse -Force -ErrorAction SilentlyContinue }

    Invoke-Git @("fetch", "origin", "gh-pages", "--depth=1") | Out-Null
    Invoke-Git @("worktree", "add", "--detach", $wtDir, "origin/gh-pages") | Out-Null
    Copy-Item $localOut (Join-Path $wtDir "live_telemetry.json") -Force
    Push-Location $wtDir
    try {
      Invoke-Git @("add", "live_telemetry.json") | Out-Null
      $diff = Invoke-Git @("status", "--porcelain", "live_telemetry.json")
      if ($diff) {
        $msg = "chore(live): sync addon telemetry " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm UTC")
        Invoke-Git @("commit", "-m", $msg) | Out-Null
        Invoke-Git @("push", "origin", "HEAD:gh-pages") | Out-Null
        Write-Host ("[{0}] Pushed live_telemetry.json -> origin/gh-pages OK!" -f (Get-Date -Format "HH:mm:ss"))
      } else {
        Write-Host ("[{0}] No telemetry changes to push." -f (Get-Date -Format "HH:mm:ss"))
      }
    } finally {
      Pop-Location
    }
  } finally {
    Invoke-Git @("worktree", "remove", "--force", $wtDir) -IgnoreError | Out-Null
    if (Test-Path $wtDir) { Remove-Item $wtDir -Recurse -Force -ErrorAction SilentlyContinue }
    Pop-Location
  }
}

if (-not $Watch) {
  Sync-Once
} else {
  Write-Host "Watching $SavedVarsPath every ${PollSeconds}s (Ctrl+C to stop)..."
  $lastWrite = [DateTime]::MinValue
  while ($true) {
    try {
      if (Test-Path $SavedVarsPath) {
        $wt = (Get-Item $SavedVarsPath).LastWriteTimeUtc
        if ($wt -gt $lastWrite) {
          $lastWrite = $wt
          Sync-Once
        }
      }
    } catch {
      Write-Warning ("Sync error: " + $_.Exception.Message)
    }
    Start-Sleep -Seconds $PollSeconds
  }
}
