Add-Type -AssemblyName System.Windows.Forms

$LogFile     = Join-Path $PSScriptRoot "tray-error.log"
$HistoryFile = Join-Path $env:USERPROFILE ".claude\claude-usage-history.json"

function Read-JsonFile($path) {
    $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    return ($raw -replace '^\xEF\xBB\xBF','') | ConvertFrom-Json
}
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { return "$([math]::Round($n/1000000,2))M" }
    if ($n -ge 1000)    { return "$([math]::Round($n/1000,1))K" }
    return "$n"
}

function Get-LocalTokenData {
    $projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
    if (-not (Test-Path $projectsDir)) { return $null }
    $byDate = @{}; $bySession = @{}; $byHour = @{}
    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    try {
        $files = Get-ChildItem $projectsDir -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            foreach ($line in $lines) {
                if (-not $line -or $line.Length -lt 10) { continue }
                try {
                    $e = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if (-not $e -or -not $e.timestamp) { continue }
                    $usage = $null; try { $usage = $e.message.usage } catch { }
                    $cost = [double]0; try { if ($null -ne $e.costUSD) { $cost = [double]$e.costUSD } } catch { }
                    if (-not $usage -and $cost -eq 0) { continue }
                    $dt = $null
                    try { $dt = [System.DateTimeOffset]::Parse("$($e.timestamp)",[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { continue }
                    $date = $dt.ToString("yyyy-MM-dd")
                    $sid = if ($e.sessionId) { "$($e.sessionId)" } else { "unknown" }
                    $model = if ($e.message.model) { "$($e.message.model)" } else { "" }
                    $inp=[long]0; $out=[long]0; $cc=[long]0; $cr=[long]0
                    if ($usage) {
                        try { $inp = [long]$usage.input_tokens } catch { }
                        try { $out = [long]$usage.output_tokens } catch { }
                        try { $cc  = [long]$usage.cache_creation_input_tokens } catch { }
                        try { $cr  = [long]$usage.cache_read_input_tokens } catch { }
                    }
                    $total = $inp + $out
                    if ($date -eq $todayStr) {
                        $hr = $dt.Hour
                        if (-not $byHour[$hr]) { $byHour[$hr] = @{ hour=$hr; inp=0L; out=0L } }
                        $byHour[$hr].inp += $inp; $byHour[$hr].out += $out
                    }
                    if (-not $byDate[$date]) { $byDate[$date] = @{ date=$date; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; models=@{} } }
                    $byDate[$date].inp += $inp; $byDate[$date].out += $out
                    $byDate[$date].cc  += $cc;  $byDate[$date].cr  += $cr
                    $byDate[$date].total += $total; $byDate[$date].cost += $cost
                    if ($model) { $byDate[$date].models[$model] = 1 }
                    if (-not $bySession[$sid]) { $bySession[$sid] = @{ sid=$sid; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; lastTs=$dt; models=@{} } }
                    $bySession[$sid].inp += $inp; $bySession[$sid].out += $out
                    $bySession[$sid].cc  += $cc;  $bySession[$sid].cr  += $cr
                    $bySession[$sid].total += $total; $bySession[$sid].cost += $cost
                    if ($dt -gt $bySession[$sid].lastTs) { $bySession[$sid].lastTs = $dt }
                    if ($model) { $bySession[$sid].models[$model] = 1 }
                } catch { }
            }
        }
    } catch { }
    if ($byDate.Count -eq 0) { return $null }
    $days     = @($byDate.Values | Sort-Object { $_.date })
    $sessions = @($bySession.Values | Sort-Object { $_.total } -Descending | Select-Object -First 20)
    return @{ Days=$days; Sessions=$sessions; Hours=$byHour }
}

$script:stats = [ordered]@{
    Session     = [ordered]@{ Utilization=42.0; ResetsAt=((Get-Date).AddMinutes(87)) }
    Week        = [ordered]@{ Utilization=61.0; ResetsAt=((Get-Date).AddDays(3)) }
    ExtraUsage  = $false
    Error       = ""
    LastUpdated = (Get-Date)
    Cached      = $false
}

# Source Show-HistoryChart from main script (extract function body only)
$src = Get-Content 'C:\Claude Projects\ClaudeUsageTray\claude-tray.ps1' -Raw -Encoding UTF8
$src = $src -replace '^\xEF\xBB\xBF',''
# Execute only the Show-HistoryChart function definition
$funcMatch = [regex]::Match($src, '(?s)(function Show-HistoryChart \{.*?\n\})\s*\n# ')
if ($funcMatch.Success) {
    Invoke-Expression $funcMatch.Groups[1].Value
    Show-HistoryChart
} else {
    Write-Host "Funzione non trovata, apertura diretta..."
    $htmlPath = Join-Path $env:TEMP "claude-usage-dashboard.html"
    if (Test-Path $htmlPath) { Start-Process $htmlPath } else { Write-Host "Dashboard non trovata" }
}
