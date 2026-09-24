# Claude Code Usage - System Tray Monitor

$LogFile = Join-Path $PSScriptRoot "tray-error.log"
if (Test-Path $LogFile) {
    if ((Get-Item $LogFile).Length -gt 102400) {
        Move-Item $LogFile (Join-Path $PSScriptRoot "tray-error.old.log") -Force -ErrorAction SilentlyContinue
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@ -Name NativeMethods -Namespace Win32 -ErrorAction SilentlyContinue

$CredFile       = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$HistoryFile    = Join-Path $env:USERPROFILE ".claude\claude-usage-history.json"
$ClientId       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$HistoryMaxDays = 30
$CooldownSec    = 30

$script:LastGoodStats    = $null
$script:LastFreshTime    = $null   # ultima volta che i dati sono arrivati DAVVERO dall'API/status line (non da cache)
$script:LoginNeeded      = $false  # true se il token e' scaduto/mancante e il refresh e' fallito: segnale immediato, non serve aspettare
$script:LastCallTime     = [datetime]::MinValue
$StaleAfterHours         = 3       # oltre questa eta' l'avviso "dati non aggiornati" compare nel menu
$script:lastIconLevel    = -1
$script:lastIconHandle   = [IntPtr]::Zero
$script:notified85       = $false
$script:notified90       = $false
$script:lastSessResetsAt = ""
$SessionEventFile        = Join-Path $PSScriptRoot "session-event.json"

# ─── Utilità ──────────────────────────────────────────────────────────────────
function Parse-IsoDate($str) {
    if (-not $str) { return $null }
    try {
        return [System.DateTimeOffset]::Parse($str,[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
    } catch { return $null }
}
function Read-JsonFile($path) {
    $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    return ($raw -replace '^\xEF\xBB\xBF','') | ConvertFrom-Json
}
function Write-JsonFile($path, $obj) {
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
}
# Semina la cache in-memory da usage-snapshot.json su disco: evita che un
# riavvio del processo (crash, watchdog, chiusura manuale) lasci il tray senza
# alcun dato quando l'API e' temporaneamente in rate-limit e non c'e' ancora
# nessuna cache fresca in RAM.
function Seed-LastGoodStats {
    $snapPath = Join-Path $PSScriptRoot "usage-snapshot.json"
    $snap = Read-JsonFile $snapPath
    if (-not $snap -or -not $snap.last_updated) { return }
    $age = ([datetime]::Now - [datetime]$snap.last_updated).TotalHours
    if ($age -gt 48) { return }  # troppo vecchio per essere utile come fallback
    $seeded = [ordered]@{
        Session     = [ordered]@{
            Utilization = if ($snap.session) { $snap.session.pct } else { $null }
            ResetsAt    = if ($snap.session) { Parse-IsoDate $snap.session.resets_at } else { $null }
        }
        Week        = [ordered]@{
            Utilization = if ($snap.week) { $snap.week.pct } else { $null }
            ResetsAt    = if ($snap.week) { Parse-IsoDate $snap.week.resets_at } else { $null }
        }
        Model       = [ordered]@{
            Name        = if ($snap.model) { $snap.model.name } else { $null }
            Utilization = if ($snap.model) { $snap.model.pct } else { $null }
            ResetsAt    = if ($snap.model) { Parse-IsoDate $snap.model.resets_at } else { $null }
        }
        ExtraUsage  = $false
        Error       = ""
        LastUpdated = [datetime]$snap.last_updated
        Cached      = $true
    }
    # last_fresh_fetch: quando l'ultimo dato VERO (non cache) e' arrivato.
    # Se lo snapshot e' vecchio (pre-fix) e non ce l'ha, usiamo last_updated
    # come stima prudente: sara' corretto al primo fetch riuscito.
    $script:LastFreshTime = if ($snap.last_fresh_fetch) { [datetime]$snap.last_fresh_fetch } else { [datetime]$snap.last_updated }
    $script:LastGoodStats = $seeded
}
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { return "$([math]::Round($n/1000000,2))M" }
    if ($n -ge 1000)    { return "$([math]::Round($n/1000,1))K" }
    return "$n"
}
$script:ptZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
function Get-PacificTime { return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $script:ptZone) }
function Get-IsPeakHour {
    # Peak = Mon-Fri 05:00-11:00 PT = 8AM-2PM ET = 12PM-6PM GMT (source: claude2x.com)
    $pt  = Get-PacificTime
    $dow = [int]$pt.DayOfWeek   # 0=Sun, 6=Sat
    return ($dow -ge 1 -and $dow -le 5 -and $pt.Hour -ge 5 -and $pt.Hour -lt 11)
}

# ─── Legge JSONL locali (~/.claude/projects/) ────────────────────────────────
function Get-LocalTokenData {
    $projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
    if (-not (Test-Path $projectsDir)) { return $null }
    $byDate    = @{}
    $bySession = @{}
    $byHour    = @{}
    $byProject = @{}
    $sessTitle = @{}
    $todayStr  = (Get-Date).ToString("yyyy-MM-dd")
    # Dedup: la stessa richiesta puo' comparire su piu' righe JSONL (retry/streaming)
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]'
    $cut7   = (Get-Date).Date.AddDays(-7)
    $cut30  = (Get-Date).Date.AddDays(-30)
    $cut24h = (Get-Date).AddHours(-24)
    function Add-MTokEntry($bucket, [string]$model, [long]$inp, [long]$out, [long]$cc, [long]$cr, [bool]$d30, [bool]$d7, [bool]$d24h, [string]$dayStr) {
        $keys = @('mtok'); if ($d30) { $keys += 'mtok30' }; if ($d7) { $keys += 'mtok7' }; if ($d24h) { $keys += 'mtok24h' }
        foreach ($k in $keys) {
            if (-not $bucket[$k][$model]) { $bucket[$k][$model] = @{ inp=0L; out=0L; cc=0L; cr=0L } }
            $t = $bucket[$k][$model]
            $t.inp += $inp; $t.out += $out; $t.cc += $cc; $t.cr += $cr
        }
        # Bucket per-giorno-calendario (per il filtro "singolo giorno" della dashboard)
        if (-not $bucket['byDay'][$dayStr]) { $bucket['byDay'][$dayStr] = @{} }
        if (-not $bucket['byDay'][$dayStr][$model]) { $bucket['byDay'][$dayStr][$model] = @{ inp=0L; out=0L; cc=0L; cr=0L } }
        $dbt = $bucket['byDay'][$dayStr][$model]
        $dbt.inp += $inp; $dbt.out += $out; $dbt.cc += $cc; $dbt.cr += $cr
    }
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
                    # Titolo sessione: primo messaggio utente testuale nel file (i messaggi utente
                    # non hanno usage token, quindi va catturato PRIMA del filtro "continue" sotto)
                    if ($e.sessionId -and $e.type -eq 'user' -and $e.message.role -eq 'user' -and $e.message.content -is [string] -and -not $sessTitle.ContainsKey("$($e.sessionId)")) {
                        $t = "$($e.message.content)".Trim() -replace '\s+',' '
                        if ($t) {
                            if ($t.Length -gt 90) { $t = $t.Substring(0,90) + '...' }
                            $sessTitle["$($e.sessionId)"] = $t
                        }
                    }
                    $usage = $null; try { $usage = $e.message.usage } catch { }
                    $cost  = [double]0; try { if ($null -ne $e.costUSD) { $cost = [double]$e.costUSD } } catch { }
                    if (-not $usage -and $cost -eq 0) { continue }
                    $dt = $null
                    try { $dt = [System.DateTimeOffset]::Parse("$($e.timestamp)",[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { continue }
                    $mid = ""; try { if ($e.message.id) { $mid = "$($e.message.id)" } } catch { }
                    $rid = ""; try { if ($e.requestId)  { $rid = "$($e.requestId)" } } catch { }
                    if (($mid -or $rid) -and -not $seen.Add("$mid|$rid")) { continue }
                    $date  = $dt.ToString("yyyy-MM-dd")
                    $sid   = if ($e.sessionId)     { "$($e.sessionId)" }     else { "unknown" }
                    $model = if ($e.message.model) { "$($e.message.model)" } else { "" }
                    $proj  = ""
                    try { if ($e.cwd) { $proj = Split-Path "$($e.cwd)" -Leaf } } catch { }
                    if (-not $proj) { $proj = $file.Directory.Name }
                    $inp=[long]0; $out=[long]0; $cc=[long]0; $cr=[long]0
                    if ($usage) {
                        try { $inp = [long]$usage.input_tokens }                    catch { }
                        try { $out = [long]$usage.output_tokens }                   catch { }
                        try { $cc  = [long]$usage.cache_creation_input_tokens }     catch { }
                        try { $cr  = [long]$usage.cache_read_input_tokens }         catch { }
                    }
                    $total = $inp + $out
                    if ($date -eq $todayStr) {
                        $hr = $dt.Hour
                        if (-not $byHour[$hr]) { $byHour[$hr] = @{ hour=$hr; inp=0L; out=0L } }
                        $byHour[$hr].inp += $inp; $byHour[$hr].out += $out
                    }
                    if (-not $byDate[$date]) {
                        $byDate[$date] = @{ date=$date; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; models=@{} }
                    }
                    $byDate[$date].inp   += $inp;  $byDate[$date].out  += $out
                    $byDate[$date].cc    += $cc;   $byDate[$date].cr   += $cr
                    $byDate[$date].total += $total; $byDate[$date].cost += $cost
                    if ($model) { $byDate[$date].models[$model] = 1 }
                    if (-not $bySession[$sid]) {
                        $bySession[$sid] = @{ sid=$sid; proj=$proj; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; lastTs=$dt; models=@{}; mtok=@{}; mtok30=@{}; mtok7=@{}; mtok24h=@{}; byDay=@{} }
                    }
                    $bySession[$sid].inp   += $inp;  $bySession[$sid].out  += $out
                    $bySession[$sid].cc    += $cc;   $bySession[$sid].cr   += $cr
                    $bySession[$sid].total += $total; $bySession[$sid].cost += $cost
                    if ($dt -gt $bySession[$sid].lastTs) { $bySession[$sid].lastTs = $dt }
                    if ($model) { $bySession[$sid].models[$model] = 1 }
                    # Token per modello: sessione e progetto (stima costi, finestre 24h/7/30 gg + per-giorno)
                    if ($model) {
                        $d30 = $dt -ge $cut30; $d7 = $dt -ge $cut7; $d24h = $dt -ge $cut24h
                        Add-MTokEntry $bySession[$sid] $model $inp $out $cc $cr $d30 $d7 $d24h $date
                        if (-not $byProject[$proj]) { $byProject[$proj] = @{ name=$proj; inp=0L; out=0L; cc=0L; cr=0L; total=0L; lastTs=$dt; mtok=@{}; mtok30=@{}; mtok7=@{}; mtok24h=@{}; byDay=@{} } }
                        $bp = $byProject[$proj]
                        $bp.inp += $inp; $bp.out += $out; $bp.cc += $cc; $bp.cr += $cr; $bp.total += $total
                        if ($dt -gt $bp.lastTs) { $bp.lastTs = $dt }
                        Add-MTokEntry $bp $model $inp $out $cc $cr $d30 $d7 $d24h $date
                    }
                } catch { }
            }
        }
    } catch { }
    if ($byDate.Count -eq 0) { return $null }
    foreach ($k in @($bySession.Keys)) {
        $bySession[$k].title = if ($sessTitle.ContainsKey($k)) { $sessTitle[$k] } else { "" }
    }
    $days     = @($byDate.Values | Sort-Object date)
    $sessions = @($bySession.Values | Sort-Object { $_.total } -Descending)
    $projects = @($byProject.Values | Sort-Object { $_.total } -Descending)
    return @{ Days=$days; Sessions=$sessions; Hours=$byHour; Projects=$projects }
}

# ─── Storico: salva entry ─────────────────────────────────────────────────────
function Save-HistoryEntry($stats) {
    if (-not $stats -or $stats.Error) { return }
    try {
        $history = @()
        if (Test-Path $HistoryFile) { $loaded = Read-JsonFile $HistoryFile; if ($loaded) { $history = @($loaded) } }
        $cutoff  = (Get-Date).AddDays(-$HistoryMaxDays)
        $history = @($history | Where-Object { $d = Parse-IsoDate $_.ts; $d -and $d -gt $cutoff })
        $history += [ordered]@{
            ts   = (Get-Date).ToString("o")
            sess = if ($null -ne $stats.Session.Utilization) { $stats.Session.Utilization } else { $null }
            week = if ($null -ne $stats.Week.Utilization)    { $stats.Week.Utilization }    else { $null }
        }
        Write-JsonFile $HistoryFile $history
    } catch { }
}

# ─── Dashboard HTML ───────────────────────────────────────────────────────────
# ─── Stima costi (prezzi API di listino $/MTok; cache write 1.25x, read 0.1x) ─
function Get-ModelPrice([string]$model) {
    if ($model -match 'fable|mythos') { return @{ inp=10.0; out=50.0 } }
    if ($model -match 'opus')         { return @{ inp=5.0;  out=25.0 } }
    if ($model -match 'sonnet')       { return @{ inp=3.0;  out=15.0 } }
    if ($model -match 'haiku')        { return @{ inp=1.0;  out=5.0 } }
    return @{ inp=5.0; out=25.0 }
}
function Get-EstCost([string]$model, [long]$inp, [long]$out, [long]$cc, [long]$cr) {
    $p = Get-ModelPrice $model
    return ($inp * $p.inp + $out * $p.out + $cc * $p.inp * 1.25 + $cr * $p.inp * 0.1) / 1000000.0
}
function Get-ShortModelName([string]$model) {
    return ($model -replace '^claude-','' -replace '-\d{8}$','')
}
# Costruisce il JS array [{m,c}] dei costi per modello di un bucket con mtok
function Get-ModelCostJs($mtok) {
    $parts = @()
    $tot = 0.0
    foreach ($m in ($mtok.Keys | Sort-Object)) {
        if ($m -match '<synthetic>' -or -not $m) { continue }
        $t = $mtok[$m]
        $c = Get-EstCost $m $t.inp $t.out $t.cc $t.cr
        $tot += $c
        $short = Get-ShortModelName $m
        $parts += "{m:`"$short`",c:$([math]::Round($c,2))}"
    }
    return @{ js = ('[' + ($parts -join ',') + ']'); total = [math]::Round($tot,2) }
}
# Costruisce l'oggetto JS {"yyyy-MM-dd":{t:costo,m:[...]}} per il filtro "singolo giorno"
function Get-ByDayJs($byDay) {
    if (-not $byDay -or $byDay.Count -eq 0) { return '{}' }
    $parts = foreach ($day in ($byDay.Keys | Sort-Object -Descending)) {
        $mc = Get-ModelCostJs $byDay[$day]
        if ($mc.total -gt 0) { "`"$day`":{t:$($mc.total),m:$($mc.js)}" }
    }
    return '{' + (($parts | Where-Object { $_ }) -join ',') + '}'
}

# ─── Analisi: prezzi reali API ($) + ratio limite settimanale (peso) ─────────
$script:AnalyticsPriceTable = @{
    Opus   = @{ pin=15.0; pout=75.0; rin=5;    rout=25 }
    Sonnet = @{ pin=3.0;  pout=15.0; rin=3;    rout=15 }
    Haiku  = @{ pin=0.80; pout=4.0;  rin=1;    rout=5 }
    Fable  = @{ pin=15.0; pout=75.0; rin=10;   rout=50 }
}
function Get-ModelTier([string]$model) {
    if ($model -match 'fable|mythos') { return 'Fable' }
    if ($model -match 'opus')         { return 'Opus' }
    if ($model -match 'sonnet')       { return 'Sonnet' }
    if ($model -match 'haiku')        { return 'Haiku' }
    return 'Sonnet'
}
function Get-AnalyticsData {
    $projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
    if (-not (Test-Path $projectsDir)) { return $null }

    $now    = Get-Date
    $cut24h = $now.AddHours(-24)
    $cut7   = $now.AddDays(-7)
    $cut30  = $now.AddDays(-30)

    # Calibrazione: K = %-settimanale-reale / peso della finestra reale (week.resets_at - 7gg)
    $st = $script:stats
    $weekPct = $null; $weekResetsAt = $null
    if ($st -and $st.Week -and $null -ne $st.Week.Utilization) {
        $weekPct      = [double]$st.Week.Utilization
        $weekResetsAt = $st.Week.ResetsAt
    }
    if ((-not $weekResetsAt) -or $null -eq $weekPct) {
        $snapPath = Join-Path $PSScriptRoot "usage-snapshot.json"
        if (Test-Path $snapPath) {
            $snap = Read-JsonFile $snapPath
            if ($snap -and $snap.week) {
                if ($null -ne $snap.week.pct) { $weekPct = [double]$snap.week.pct }
                if ($snap.week.resets_at) { $weekResetsAt = $snap.week.resets_at }
            }
        }
    }
    # Normalizza resets_at: puo' essere DateTime (path in-process), unix seconds o stringa ISO (snapshot)
    if ($weekResetsAt -and $weekResetsAt -isnot [datetime]) {
        $rv = "$weekResetsAt"
        if ($rv -match '^\d+$') {
            try { $weekResetsAt = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$rv).LocalDateTime } catch { $weekResetsAt = $null }
        } else {
            try { $weekResetsAt = [System.DateTimeOffset]::Parse($rv, [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { $weekResetsAt = $null }
        }
    }
    $windowStart = if ($weekResetsAt -is [datetime]) { $weekResetsAt.AddDays(-7) } else { $null }
    $weekPeso    = [double]0

    $periods = @{}
    foreach ($p in @('24h','7d','30d','all')) { $periods[$p] = @{ models=@{}; sessions=@{}; projects=@{} } }
    $trendBuckets = @{ '24h'=@{}; '7d'=@{}; '30d'=@{}; 'all'=@{} }

    function Add-Analytics($bucket, [string]$tier, [string]$sid, [string]$proj, [long]$inp, [long]$out, [long]$cr, [long]$c5, [long]$c1, [double]$usd, [double]$peso) {
        $cc = $c5 + $c1
        if (-not $bucket.models[$tier]) { $bucket.models[$tier] = @{ inp=0L; out=0L; cr=0L; cc=0L; c5=0L; c1=0L; usd=0.0; peso=0.0 } }
        $m = $bucket.models[$tier]
        $m.inp += $inp; $m.out += $out; $m.cr += $cr; $m.cc += $cc; $m.c5 += $c5; $m.c1 += $c1; $m.usd += $usd; $m.peso += $peso

        if (-not $bucket.sessions[$sid]) { $bucket.sessions[$sid] = @{ proj=$proj; models=@{}; byModel=@{}; inp=0L; out=0L; cr=0L; cc=0L; usd=0.0; peso=0.0 } }
        $s = $bucket.sessions[$sid]
        $s.inp += $inp; $s.out += $out; $s.cr += $cr; $s.cc += $cc; $s.usd += $usd; $s.peso += $peso
        $s.models[$tier] = 1
        if ($proj) { $s.proj = $proj }
        if (-not $s.byModel[$tier]) { $s.byModel[$tier] = @{ inp=0L; out=0L; cr=0L; c5=0L; c1=0L; usd=0.0; peso=0.0 } }
        $sm = $s.byModel[$tier]
        $sm.inp += $inp; $sm.out += $out; $sm.cr += $cr; $sm.c5 += $c5; $sm.c1 += $c1; $sm.usd += $usd; $sm.peso += $peso

        if (-not $bucket.projects[$proj]) { $bucket.projects[$proj] = @{ models=@{}; inp=0L; out=0L; cr=0L; cc=0L; usd=0.0; peso=0.0 } }
        $pr = $bucket.projects[$proj]
        $pr.inp += $inp; $pr.out += $out; $pr.cr += $cr; $pr.cc += $cc; $pr.usd += $usd; $pr.peso += $peso
        $pr.models[$tier] = 1
    }

    function Add-Trend($tb, [string]$key, [string]$tier, [long]$inp, [long]$out, [long]$cr, [long]$c5, [long]$c1, [double]$usd, [double]$peso) {
        if (-not $tb[$key]) { $tb[$key] = @{ peso=0.0; usd=0.0; cheapPeso=0.0; pesoIn=0.0; pesoOut=0.0; pesoCacheRC=0.0; sumInp=0.0; sumCr=0.0; sumCc=0.0 } }
        $b = $tb[$key]
        $b.peso += $peso; $b.usd += $usd
        if ($tier -eq 'Sonnet' -or $tier -eq 'Haiku') { $b.cheapPeso += $peso }
        $p = $script:AnalyticsPriceTable[$tier]
        $b.pesoIn      += $inp * $p.rin / 1000000.0
        $b.pesoOut     += $out * $p.rout / 1000000.0
        $b.pesoCacheRC += ($cr*$p.rin*0.10 + $c5*$p.rin*1.25 + $c1*$p.rin*2.00) / 1000000.0
        $b.sumInp += $inp; $b.sumCr += $cr; $b.sumCc += ($c5 + $c1)
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
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
                    if (-not $usage) { continue }
                    $dt = $null
                    try { $dt = [System.DateTimeOffset]::Parse("$($e.timestamp)",[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { continue }
                    $mid = ""; try { if ($e.message.id) { $mid = "$($e.message.id)" } } catch { }
                    $rid = ""; try { if ($e.requestId)  { $rid = "$($e.requestId)" } } catch { }
                    if (($mid -or $rid) -and -not $seen.Add("$mid|$rid")) { continue }
                    $model = if ($e.message.model) { "$($e.message.model)" } else { "" }
                    if (-not $model) { continue }
                    $sid  = if ($e.sessionId) { "$($e.sessionId)" } else { "unknown" }
                    $proj = ""
                    try { if ($e.cwd) { $proj = Split-Path "$($e.cwd)" -Leaf } } catch { }
                    if (-not $proj) { $proj = $file.Directory.Name }

                    $inp=[long]0; $out=[long]0; $cc=[long]0; $cr=[long]0; $c5=[long]0; $c1=[long]0
                    try { $inp = [long]$usage.input_tokens }                catch { }
                    try { $out = [long]$usage.output_tokens }               catch { }
                    try { $cc  = [long]$usage.cache_creation_input_tokens } catch { }
                    try { $cr  = [long]$usage.cache_read_input_tokens }     catch { }
                    if ($usage.cache_creation) {
                        try { $c5 = [long]$usage.cache_creation.ephemeral_5m_input_tokens } catch { }
                        try { $c1 = [long]$usage.cache_creation.ephemeral_1h_input_tokens } catch { }
                    }
                    if ($c5 -eq 0 -and $c1 -eq 0 -and $cc -gt 0) { $c5 = $cc }

                    $tier  = Get-ModelTier $model
                    $price = $script:AnalyticsPriceTable[$tier]
                    $usd  = ($inp*$price.pin + $out*$price.pout + $cr*$price.pin*0.10 + $c5*$price.pin*1.25 + $c1*$price.pin*2.00) / 1000000.0
                    $peso = ($inp*$price.rin + $out*$price.rout + $cr*$price.rin*0.10 + $c5*$price.rin*1.25 + $c1*$price.rin*2.00) / 1000000.0

                    if ($windowStart -and $dt -ge $windowStart) { $weekPeso += $peso }

                    if ($dt -ge $cut24h) { Add-Analytics $periods['24h'] $tier $sid $proj $inp $out $cr $c5 $c1 $usd $peso }
                    if ($dt -ge $cut7)   { Add-Analytics $periods['7d']  $tier $sid $proj $inp $out $cr $c5 $c1 $usd $peso }
                    if ($dt -ge $cut30)  { Add-Analytics $periods['30d'] $tier $sid $proj $inp $out $cr $c5 $c1 $usd $peso }
                    Add-Analytics $periods['all'] $tier $sid $proj $inp $out $cr $c5 $c1 $usd $peso

                    if ($dt -ge $cut24h) { Add-Trend $trendBuckets['24h'] $dt.ToString("yyyy-MM-dd HH:00") $tier $inp $out $cr $c5 $c1 $usd $peso }
                    $dayKey = $dt.ToString("yyyy-MM-dd")
                    if ($dt -ge $cut7)   { Add-Trend $trendBuckets['7d']  $dayKey $tier $inp $out $cr $c5 $c1 $usd $peso }
                    if ($dt -ge $cut30)  { Add-Trend $trendBuckets['30d'] $dayKey $tier $inp $out $cr $c5 $c1 $usd $peso }
                    Add-Trend $trendBuckets['all'] $dayKey $tier $inp $out $cr $c5 $c1 $usd $peso
                } catch { }
            }
        }
    } catch { }

    $K = $null; $calibValid = $false
    if ($weekPeso -gt 0 -and $weekPct -and $weekPct -gt 0) { $K = $weekPct / $weekPeso; $calibValid = $true }

    function Get-TierMult([string]$tier) {
        $rout      = $script:AnalyticsPriceTable[$tier].rout
        $haikuRout = $script:AnalyticsPriceTable['Haiku'].rout
        return [math]::Round($rout / $haikuRout, 0)
    }

    function Build-Trend($tb) {
        $rows = @()
        # Nota: variabile di loop chiamata $bktKey (non $k) perche' PowerShell e' case-insensitive
        # sui nomi variabile: $k collide con $K (fattore di calibrazione) dello scope esterno.
        foreach ($bktKey in ($tb.Keys | Sort-Object)) {
            $b      = $tb[$bktKey]
            $peso   = $b.peso
            $estPct = if ($calibValid) { [math]::Round($peso * $K, 1) } else { $null }
            $denom  = $b.sumInp + $b.sumCr + $b.sumCc
            $cacheHitPct  = if ($denom -gt 0) { [math]::Round($b.sumCr/$denom*100,1) } else { 0 }
            $cheapTierPct = if ($peso -gt 0)  { [math]::Round($b.cheapPeso/$peso*100,1) } else { 0 }
            $pesoInPct    = if ($peso -gt 0)  { [math]::Round($b.pesoIn/$peso*100,1) } else { 0 }
            $pesoOutPct   = if ($peso -gt 0)  { [math]::Round($b.pesoOut/$peso*100,1) } else { 0 }
            $pesoCachePct = if ($peso -gt 0)  { [math]::Round($b.pesoCacheRC/$peso*100,1) } else { 0 }
            $rows += [ordered]@{
                label = $bktKey; peso = [math]::Round($peso,2); usd = [math]::Round($b.usd,2); estPct = $estPct
                cacheHitPct = $cacheHitPct; cheapTierPct = $cheapTierPct
                pesoInPct = $pesoInPct; pesoOutPct = $pesoOutPct; pesoCachePct = $pesoCachePct
            }
        }
        return $rows
    }

    function Build-PeriodJson($bucket, $trend) {
        $totInp=0.0;$totOut=0.0;$totCr=0.0;$totCc=0.0;$totPeso=0.0;$totUsd=0.0
        $cheapPeso = 0.0
        $pesoIn=0.0;$pesoOut=0.0;$pesoCache=0.0
        $models = @()
        foreach ($tier in @('Opus','Sonnet','Haiku','Fable')) {
            if (-not $bucket.models[$tier]) { continue }
            $m = $bucket.models[$tier]
            if ($m.inp -eq 0 -and $m.out -eq 0 -and $m.cr -eq 0 -and $m.cc -eq 0) { continue }
            $estPct = if ($calibValid) { [math]::Round($m.peso * $K, 1) } else { $null }
            $totInp += $m.inp; $totOut += $m.out; $totCr += $m.cr; $totCc += $m.cc; $totPeso += $m.peso; $totUsd += $m.usd
            if ($tier -eq 'Haiku' -or $tier -eq 'Sonnet') { $cheapPeso += $m.peso }
            $p = $script:AnalyticsPriceTable[$tier]
            $pesoIn    += $m.inp * $p.rin / 1000000.0
            $pesoOut   += $m.out * $p.rout / 1000000.0
            $pesoCache += ($m.cr*$p.rin*0.10 + $m.c5*$p.rin*1.25 + $m.c1*$p.rin*2.00) / 1000000.0
            $models += [ordered]@{
                name = $tier; tierLabel = "$(Get-TierMult $tier)×"
                input = $m.inp; output = $m.out; cacheRead = $m.cr; cacheCreate = $m.cc
                cacheCreate5m = $m.c5; cacheCreate1h = $m.c1
                peso = [math]::Round($m.peso,2); usd = [math]::Round($m.usd,2)
                estPct = $estPct
            }
        }
        foreach ($mm in $models) { $mm.share = if ($totPeso -gt 0) { [math]::Round($mm.peso / $totPeso * 100, 1) } else { 0 } }

        $sessRows = @()
        foreach ($sid in $bucket.sessions.Keys) {
            $s = $bucket.sessions[$sid]
            $short  = if ($sid.Length -gt 8) { $sid.Substring($sid.Length-8) } else { $sid }
            $estPct = if ($calibValid) { [math]::Round($s.peso * $K, 1) } else { $null }
            $modelDetail = @()
            foreach ($mt in $s.byModel.Keys) {
                $sm = $s.byModel[$mt]
                $mEstPct = if ($calibValid) { [math]::Round($sm.peso * $K, 1) } else { $null }
                $mShare  = if ($s.peso -gt 0) { [math]::Round($sm.peso / $s.peso * 100, 1) } else { 0 }
                $modelDetail += [pscustomobject]@{ peso=$sm.peso; js=[ordered]@{
                    name=$mt; tierLabel="$(Get-TierMult $mt)×"
                    input=$sm.inp; output=$sm.out; cacheRead=$sm.cr
                    cacheCreate5m=$sm.c5; cacheCreate1h=$sm.c1
                    peso=[math]::Round($sm.peso,2); usd=[math]::Round($sm.usd,2)
                    estPct=$mEstPct; share=$mShare
                }}
            }
            $modelDetailSorted = @($modelDetail | Sort-Object peso -Descending | ForEach-Object { $_.js })
            $sessRows += [pscustomobject]@{ peso=$s.peso; js=[ordered]@{
                id=$short; fullId=$sid; project=$s.proj; models=@($s.models.Keys | Sort-Object)
                input=$s.inp; output=$s.out; cacheRead=$s.cr; cacheCreate=$s.cc
                peso=[math]::Round($s.peso,2); usd=[math]::Round($s.usd,2); estPct=$estPct
                modelDetail=$modelDetailSorted
            }}
        }
        $sessTop = @($sessRows | Sort-Object peso -Descending | Select-Object -First 15 | ForEach-Object { $_.js })

        $projRows = @()
        foreach ($pn in $bucket.projects.Keys) {
            $pr = $bucket.projects[$pn]
            $estPct = if ($calibValid) { [math]::Round($pr.peso * $K, 1) } else { $null }
            $projRows += [pscustomobject]@{ peso=$pr.peso; js=[ordered]@{
                name=$pn; models=@($pr.models.Keys | Sort-Object)
                input=$pr.inp; output=$pr.out; cacheRead=$pr.cr; cacheCreate=$pr.cc
                peso=[math]::Round($pr.peso,2); usd=[math]::Round($pr.usd,2); estPct=$estPct
            }}
        }
        $projSorted = @($projRows | Sort-Object peso -Descending | ForEach-Object { $_.js })

        $cacheHitPct  = if (($totInp+$totCr+$totCc) -gt 0) { [math]::Round($totCr/($totInp+$totCr+$totCc)*100,1) } else { 0 }
        $cheapTierPct = if ($totPeso -gt 0) { [math]::Round($cheapPeso/$totPeso*100,1) } else { 0 }
        $totEstPct    = if ($calibValid) { [math]::Round($totPeso * $K, 1) } else { $null }
        $pesoInPct    = if ($totPeso -gt 0) { [math]::Round($pesoIn/$totPeso*100,1) }    else { 0 }
        $pesoOutPct   = if ($totPeso -gt 0) { [math]::Round($pesoOut/$totPeso*100,1) }   else { 0 }
        $pesoCachePct = if ($totPeso -gt 0) { [math]::Round($pesoCache/$totPeso*100,1) } else { 0 }

        return [ordered]@{
            models   = $models
            sessions = $sessTop
            projects = $projSorted
            totals   = [ordered]@{
                input=$totInp; output=$totOut; cacheRead=$totCr; cacheCreate=$totCc
                peso=[math]::Round($totPeso,2); usd=[math]::Round($totUsd,2); estPct=$totEstPct
                cacheHitPct=$cacheHitPct; cheapTierPct=$cheapTierPct
                pesoInPct=$pesoInPct; pesoOutPct=$pesoOutPct; pesoCachePct=$pesoCachePct
            }
            trend    = $trend
        }
    }

    $result = [ordered]@{
        calib = [ordered]@{
            K = $K; weekPct = $weekPct
            windowStart = if ($windowStart) { $windowStart.ToString("o") } else { $null }
            valid = $calibValid
        }
    }
    foreach ($p in @('24h','7d','30d','all')) { $result[$p] = Build-PeriodJson $periods[$p] (Build-Trend $trendBuckets[$p]) }
    return $result
}

function Show-HistoryChart {
  try {
    $history = @()
    if (Test-Path $HistoryFile) { $loaded = Read-JsonFile $HistoryFile; if ($loaded) { $history = @($loaded) } }

    $jsRows = ($history | ForEach-Object {
        $ts = if ($_.ts -match '^\d{4}-\d{2}-\d{2}T[\d:+.\-Z]+$') { $_.ts } else { '' }
        $s  = if ("$($_.sess)" -match '^\d+(\.\d+)?$') { $_.sess } else { 'null' }
        $w  = if ("$($_.week)" -match '^\d+(\.\d+)?$') { $_.week } else { 'null' }
        if ($ts) { "{ts:`"$ts`",sess:$s,week:$w}" }
    }) -join ','

    $localData   = Get-LocalTokenData
    $days        = if ($localData) { @($localData.Days     | Sort-Object { $_.date }) } else { @() }
    $allSessions = if ($localData) { @($localData.Sessions | Sort-Object { $_.total } -Descending) } else { @() }
    $sessions    = @($allSessions | Select-Object -First 15)

    $jsDays = if ($days.Count) {
        '[' + (($days | ForEach-Object {
            $mods = ($_.models.Keys |
                     Where-Object { $_ -notmatch '<synthetic>|^$' } |
                     ForEach-Object { $_ -replace 'claude-','' -replace '-\d{8}$','' } |
                     Sort-Object -Unique) -join ', '
            $dt2 = [long]$_.inp + [long]$_.out
            "{date:`"$($_.date)`",total:$dt2,inp:$($_.inp),out:$($_.out),models:`"$mods`"}"
        }) -join ',') + ']'
    } else { '[]' }

    $jsSessions = if ($sessions.Count) {
        $i = 0
        '[' + (($sessions | ForEach-Object {
            $i++
            $lts = if ($_.lastTs) { $_.lastTs.ToString("o") } else { '' }
            $dt2 = [long]$_.inp + [long]$_.out
            "{n:$i,total:$dt2,lastTs:`"$lts`"}"
        }) -join ',') + ']'
    } else { '[]' }

    # Costi stimati per sessione e per progetto, con finestre 7/30 giorni e totale.
    # Usa TUTTE le sessioni (non il top-15 per token storici): altrimenti una sessione
    # piccola nel totale ma attiva negli ultimi 7gg sparirebbe anche da quella vista.
    $jsSessCost = if ($allSessions.Count) {
        $rows = foreach ($s in $allSessions) {
            if (-not $s.mtok -or $s.mtok.Count -eq 0) { continue }
            $mcA = Get-ModelCostJs $s.mtok; $mc30 = Get-ModelCostJs $s.mtok30; $mc7 = Get-ModelCostJs $s.mtok7; $mc24h = Get-ModelCostJs $s.mtok24h; $byDayJs = Get-ByDayJs $s.byDay
            $sidShort = if ("$($s.sid)".Length -gt 8) { "$($s.sid)".Substring(0,8) } else { "$($s.sid)" }
            $lts = if ($s.lastTs) { $s.lastTs.ToString("o") } else { '' }
            $pj  = "$($s.proj)" -replace '["\\]',''
            $ttl = if ($s.title) { "$($s.title)" -replace '["\\]','' -replace "[\r\n]",' ' } else { '' }
            [pscustomobject]@{ total = $mcA.total; js = "{sid:`"$sidShort`",title:`"$ttl`",proj:`"$pj`",lastTs:`"$lts`",t_all:$($mcA.total),m_all:$($mcA.js),t_30:$($mc30.total),m_30:$($mc30.js),t_7:$($mc7.total),m_7:$($mc7.js),t_24h:$($mc24h.total),m_24h:$($mc24h.js),byDay:$byDayJs}" }
        }
        '[' + ((@($rows) | Sort-Object total -Descending | ForEach-Object { $_.js }) -join ',') + ']'
    } else { '[]' }
    $projList = if ($localData -and $localData.Projects) { @($localData.Projects) } else { @() }
    $jsProjCost = if ($projList.Count) {
        $rows = foreach ($p2 in $projList) {
            if (-not $p2.mtok -or $p2.mtok.Count -eq 0) { continue }
            $mcA = Get-ModelCostJs $p2.mtok; $mc30 = Get-ModelCostJs $p2.mtok30; $mc7 = Get-ModelCostJs $p2.mtok7; $mc24h = Get-ModelCostJs $p2.mtok24h; $byDayJs = Get-ByDayJs $p2.byDay
            $nm = "$($p2.name)" -replace '["\\]',''
            $lts = if ($p2.lastTs) { $p2.lastTs.ToString("o") } else { '' }
            [pscustomobject]@{ total = $mcA.total; js = "{name:`"$nm`",lastTs:`"$lts`",t_all:$($mcA.total),m_all:$($mcA.js),t_30:$($mc30.total),m_30:$($mc30.js),t_7:$($mc7.total),m_7:$($mc7.js),t_24h:$($mc24h.total),m_24h:$($mc24h.js),byDay:$byDayJs}" }
        }
        '[' + ((@($rows) | Sort-Object total -Descending | ForEach-Object { $_.js }) -join ',') + ']'
    } else { '[]' }

    $jsHours = '[' + ((0..23 | ForEach-Object {
        $h2 = $_; $hd = if ($localData -and $localData.Hours) { $localData.Hours[$h2] } else { $null }
        if ($hd) { [long]$hd.inp + [long]$hd.out } else { 0 }
    }) -join ',') + ']'

    $st     = $script:stats
    $sessU  = if ($null -ne $st.Session.Utilization) { [double]$st.Session.Utilization } else { $null }
    $weekU  = if ($null -ne $st.Week.Utilization)    { [double]$st.Week.Utilization }    else { $null }
    $lastSess   = if ($null -ne $sessU) { "$sessU" } else { "?" }
    $lastWeek   = if ($null -ne $weekU) { "$weekU" } else { "?" }
    $sessBarPct = if ($null -ne $sessU) { [math]::Min(100,[math]::Max(0,[int]$sessU)) } else { 0 }
    $weekBarPct = if ($null -ne $weekU) { [math]::Min(100,[math]::Max(0,[int]$weekU)) } else { 0 }
    $lastUpd    = if ($st -and $st.LastUpdated) { $st.LastUpdated.ToString("MM/dd/yyyy HH:mm:ss") } else { "never" }
    $isCached   = if ($st.Cached) { " (cached)" } else { "" }

    function ColU($v, $resetsAt, [double]$windowHours) {
        # Colore basato sullo scostamento dal ritmo atteso (pacing), non sul valore assoluto:
        # verde = sotto il previsto, giallo = in linea/leggermente sopra, rosso = pesantemente sopra.
        if ($null -eq $v)  { return '#44aa66' }
        if ($v -ge 95)     { return '#7a0000' }  # quasi esaurito: allarme indipendente dal ritmo
        $pace = if ($resetsAt -and $windowHours) { Get-Pace ([double]$v) $resetsAt $windowHours } else { $null }
        if (-not $pace) {
            # fallback su soglie assolute se manca il dato per calcolare il ritmo atteso
            if ($v -ge 80) { return '#cc2222' } elseif ($v -ge 50) { return '#cc8800' } else { return '#44aa66' }
        }
        if ($pace.Delta -le -1)    { '#44aa66' }
        elseif ($pace.Delta -le 7) { '#cc8800' }
        else                       { '#cc2222' }
    }
    $sessColor = ColU $sessU $st.Session.ResetsAt 5
    $weekColor = ColU $weekU $st.Week.ResetsAt 168

    $sessReset = if ($st.Session.ResetsAt) {
        $m = [math]::Round(($st.Session.ResetsAt - (Get-Date)).TotalMinutes)
        if ($m -le 0) { "now" } elseif ($m -lt 60) { "in ${m} min" } else { "at " + $st.Session.ResetsAt.ToString("HH:mm") }
    } else { "unknown" }
    $weekReset = if ($st.Week.ResetsAt) {
        $d2 = [math]::Ceiling(($st.Week.ResetsAt - (Get-Date)).TotalDays)
        if ($d2 -le 0) { "today" } elseif ($d2 -eq 1) { "tomorrow" } else { "in $d2 days (" + $st.Week.ResetsAt.ToString("ddd MM/dd") + ")" }
    } else { "unknown" }

    $today    = (Get-Date).ToString("yyyy-MM-dd")
    $yest     = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    $todayRow = $days | Where-Object { $_.date -eq $today } | Select-Object -First 1
    $yestRow  = $days | Where-Object { $_.date -eq $yest }  | Select-Object -First 1
    $todayTk  = if ($todayRow) { [long]$todayRow.inp + [long]$todayRow.out } else { 0 }
    $yestTk   = if ($yestRow)  { [long]$yestRow.inp  + [long]$yestRow.out  } else { 0 }
    $weekStart = (Get-Date).AddDays(-6).ToString("yyyy-MM-dd")
    $monthStr  = (Get-Date).ToString("yyyy-MM")
    $weekTk    = [long]0
    foreach ($dw in @($days | Where-Object { $_.date -ge $weekStart }))  { $weekTk  += [long]$dw.inp + [long]$dw.out }
    $monthTk   = [long]0
    foreach ($dm in @($days | Where-Object { $_.date -like "$monthStr*" })) { $monthTk += [long]$dm.inp + [long]$dm.out }

    $sessVals = @($history | Where-Object { "$($_.sess)" -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_.sess })
    $weekVals = @($history | Where-Object { "$($_.week)" -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_.week })
    $sAvg = if ($sessVals.Count) { [math]::Round(($sessVals|Measure-Object -Average).Average,1) } else { 'null' }
    $sMax = if ($sessVals.Count) { [math]::Round(($sessVals|Measure-Object -Maximum).Maximum,1) } else { 'null' }
    $wAvg = if ($weekVals.Count) { [math]::Round(($weekVals|Measure-Object -Average).Average,1) } else { 'null' }
    $wMax = if ($weekVals.Count) { [math]::Round(($weekVals|Measure-Object -Maximum).Maximum,1) } else { 'null' }

    $totalTk   = [long]0
    foreach ($dd in $days) { $totalTk += ([long]$dd.inp + [long]$dd.out) }
    $avgDayTk  = if ($days.Count) { [long]($totalTk / $days.Count) } else { 0L }
    $peakDay   = if ($days.Count) { $days | Sort-Object { [long]$_.inp + [long]$_.out } -Descending | Select-Object -First 1 } else { $null }
    $peakDateStr = if ($peakDay) { $peakDay.date } else { '' }
    $peakTkVal   = if ($peakDay) { [long]$peakDay.inp + [long]$peakDay.out } else { 0 }
    $hasLocal    = if ($days.Count -gt 0) { 'true' } else { 'false' }
    $count       = $history.Count
    $daysCount   = $days.Count

    $analyticsData = Get-AnalyticsData
    if (-not $analyticsData) {
        $analyticsData = [ordered]@{ calib = [ordered]@{ K=$null; weekPct=$null; windowStart=$null; valid=$false } }
        foreach ($p in @('24h','7d','30d','all')) {
            $analyticsData[$p] = [ordered]@{ models=@(); sessions=@(); projects=@(); trend=@(); totals=[ordered]@{ input=0;output=0;cacheRead=0;cacheCreate=0;peso=0;usd=0;estPct=$null;cacheHitPct=0;cheapTierPct=0;pesoInPct=0;pesoOutPct=0;pesoCachePct=0 } }
        }
    }
    $analyticsJson = $analyticsData | ConvertTo-Json -Depth 10 -Compress

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Code Usage</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0f0f0f;--bg2:#181818;--bg3:#222;--border:#2e2e2e;--text:#e8e8e8;--muted:#888;--accent:#d97706;--blue:#3b82f6;--green:#22c55e;--red:#ef4444;--orange:#f59e0b;--purple:#a855f7}
@media(prefers-color-scheme:light){:root{--bg:#f4f4f4;--bg2:#fff;--bg3:#f0f0f0;--border:#ddd;--text:#111;--muted:#666}}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);padding:20px;max-width:1000px;margin:0 auto;font-size:15px;line-height:1.4}
.hdr{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;margin-bottom:18px;padding-bottom:14px;border-bottom:1px solid var(--border)}
.hdr h1{font-size:1.05rem;color:var(--accent);font-weight:700}
.meta{font-size:.78rem;color:var(--muted)}
.qrow{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}
@media(max-width:560px){.qrow,.krow{grid-template-columns:1fr}}
.qcard{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px 20px}
.qlbl{font-size:.69rem;color:var(--muted);text-transform:uppercase;letter-spacing:.07em;margin-bottom:5px}
.qpct{font-size:2.4rem;font-weight:800;line-height:1;margin-bottom:6px}
.qbar{height:8px;background:var(--bg3);border-radius:4px;overflow:hidden;margin-bottom:7px}
.qbar-f{height:100%;border-radius:4px}
.qmeta{font-size:.79rem;color:var(--muted)}
.qmeta strong{color:var(--text)}
.tabs{display:flex;gap:4px;margin-bottom:14px;border-bottom:2px solid var(--border);padding-bottom:0}
.tab{background:none;border:none;border-bottom:2px solid transparent;margin-bottom:-2px;padding:8px 18px;cursor:pointer;font-size:.82rem;color:var(--muted);font-family:inherit;transition:color .15s}
.tab:hover{color:var(--text)}
.tab.active{color:var(--accent);border-bottom-color:var(--accent);font-weight:600}
.panel{display:none}
.panel.active{display:block}
.krow{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:14px}
.kpi{background:var(--bg2);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
.kl{font-size:.67rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px}
.kv{font-size:1.45rem;font-weight:700;line-height:1}
.ks{font-size:.69rem;color:var(--muted);margin-top:4px}
.blu{color:var(--blue)}.grn{color:var(--green)}.org{color:var(--orange)}.pur{color:var(--purple)}
.up{color:var(--orange)}.dn{color:var(--green)}
.sec{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px 20px;margin-bottom:14px}
.st{font-size:.82rem;font-weight:700;margin-bottom:3px}
.ss{font-size:.71rem;color:var(--muted);margin-bottom:12px}
.rbar{display:flex;align-items:center;gap:8px;margin-bottom:12px;flex-wrap:wrap}
.rtab{background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:4px 14px;cursor:pointer;font-size:.75rem;color:var(--muted);font-family:inherit}
.rtab.active{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
.rinfo{font-size:.71rem;color:var(--muted)}
canvas{width:100%!important;display:block}
.legend{display:flex;gap:14px;margin-top:10px;font-size:.73rem;color:var(--muted);flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px;vertical-align:middle}
table{width:100%;border-collapse:collapse;font-size:.81rem}
th{text-align:left;padding:7px 10px;color:var(--muted);font-size:.67rem;text-transform:uppercase;letter-spacing:.05em;border-bottom:1px solid var(--border)}
td{padding:7px 10px;border-bottom:1px solid var(--border)}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--bg3)}
.num{text-align:right;font-variant-numeric:tabular-nums;font-family:'Consolas',monospace}
.s2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media(max-width:560px){.s2{grid-template-columns:1fr}}
.sr{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid var(--border);font-size:.82rem}
.sr:last-child{border-bottom:none}
.sk{color:var(--muted)}.sv{font-weight:600}
.nodata{text-align:center;padding:28px;color:var(--muted);font-size:.84rem}
.hint{cursor:help;opacity:.5;font-size:.85em;margin-left:4px}
</style>
</head>
<body>
<div class="hdr">
  <h1>Claude Code &mdash; Usage Monitor</h1>
  <span class="meta">Updated: $lastUpd$isCached</span>
</div>

<div class="qrow">
  <div class="qcard">
    <div class="qlbl">Session quota &mdash; 5h window</div>
    <div class="qpct" style="color:$sessColor">$lastSess%</div>
    <div class="qbar"><div class="qbar-f" style="width:${sessBarPct}%;background:$sessColor"></div></div>
    <div class="qmeta">Resets: <strong>$sessReset</strong></div>
  </div>
  <div class="qcard">
    <div class="qlbl">Weekly quota &mdash; 7d window</div>
    <div class="qpct" style="color:$weekColor">$lastWeek%</div>
    <div class="qbar"><div class="qbar-f" style="width:${weekBarPct}%;background:$weekColor"></div></div>
    <div class="qmeta">Resets: <strong>$weekReset</strong></div>
  </div>
</div>

<nav class="tabs">
  <button class="tab active" data-tab="today" onclick="switchTab('today')">Today</button>
  <button class="tab" data-tab="week" onclick="switchTab('week')">This Week</button>
  <button class="tab" data-tab="month" onclick="switchTab('month')">This Month</button>
  <button class="tab" data-tab="history" onclick="switchTab('history')">All Time</button>
  <button class="tab" data-tab="costs" onclick="switchTab('costs')">Costs</button>
  <button class="tab" data-tab="analisi" onclick="switchTab('analisi')">Analisi</button>
  <button class="tab" data-tab="grafici" onclick="switchTab('grafici')">Grafici</button>
</nav>

<!-- TODAY -->
<div id="tab-today" class="panel active">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens today</div><div class="kv blu" id="kT1">--</div><div class="ks" id="kT1s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">vs Yesterday</div><div class="kv" id="kT2">--</div><div class="ks" id="kT2s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Sessions today</div><div class="kv grn" id="kT3">--</div><div class="ks">active today</div></div>
    <div class="kpi"><div class="kl">Peak hour</div><div class="kv org" id="kT4">--</div><div class="ks" id="kT4s">&nbsp;</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens by hour</div>
    <div class="ss">Input + output tokens per hour for today. Blue = low, orange = medium, red = high relative to peak.</div>
    <canvas id="cHour" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Sessions active today</div>
    <div id="tblToday"></div>
  </div>
</div>

<!-- THIS WEEK -->
<div id="tab-week" class="panel">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens this week</div><div class="kv blu" id="kW1">--</div><div class="ks">last 7 days</div></div>
    <div class="kpi"><div class="kl">Active days</div><div class="kv grn" id="kW2">--</div><div class="ks">out of 7</div></div>
    <div class="kpi"><div class="kl">Peak day</div><div class="kv org" id="kW3" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kW3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kW4">--</div><div class="ks">tokens / day</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens per day &mdash; last 7 days</div>
    <canvas id="cWeek" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Day breakdown</div>
    <div id="tblWeek"></div>
  </div>
</div>

<!-- THIS MONTH -->
<div id="tab-month" class="panel">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens this month</div><div class="kv blu" id="kM1">--</div><div class="ks" id="kM1s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Active days</div><div class="kv grn" id="kM2">--</div><div class="ks">this month</div></div>
    <div class="kpi"><div class="kl">Peak day</div><div class="kv org" id="kM3" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kM3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kM4">--</div><div class="ks">tokens / day</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens per day &mdash; this month</div>
    <canvas id="cMonth" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Day breakdown</div>
    <div id="tblMonth"></div>
  </div>
</div>

<!-- ALL TIME -->
<div id="tab-history" class="panel">
  <div class="sec">
    <div class="st">Quota usage over time</div>
    <div class="ss">Percentage of quota consumed per measurement. A drop to 0 is normal &mdash; the window expired and reset.</div>
    <div class="rbar">
      <button class="rtab active" onclick="setRange(1)">Last 24h</button>
      <button class="rtab" onclick="setRange(7)">Last 7 days</button>
      <button class="rtab" onclick="setRange(30)">All history</button>
      <span class="rinfo" id="rInfo"></span>
    </div>
    <canvas id="cUsage" height="200"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:#d97706"></span>Session (5h)</span>
      <span><span class="dot" style="background:#3b82f6"></span>Weekly (7d)</span>
      <span style="opacity:.55"><span class="dot" style="background:#f59e0b;border-radius:2px"></span>Warning threshold (80%)</span>
      <span style="opacity:.55"><span class="dot" style="background:#ef4444;border-radius:2px"></span>Critical threshold (95%)</span>
    </div>
  </div>
  <div class="krow">
    <div class="kpi"><div class="kl">Total tokens</div><div class="kv blu" id="kH1">--</div><div class="ks">all time</div></div>
    <div class="kpi"><div class="kl">All-time peak</div><div class="kv org" id="kH2" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kH2s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kH3">--</div><div class="ks" id="kH3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Avg session quota</div><div class="kv" id="kH4">--</div><div class="ks">$count measurements</div></div>
  </div>
  <div class="sec">
    <div class="st">Top sessions</div>
    <div class="ss">Top 15 sessions by token usage. One session = one conversation with Claude.</div>
    <div id="tblSess"></div>
  </div>
  <div class="sec">
    <div class="st">All days</div>
    <div id="tblAll"></div>
  </div>
  <div class="sec">
    <div class="st">Statistics summary</div>
    <div class="ss">Based on $count quota measurements and $daysCount days of local logs.</div>
    <div class="s2">
      <div>
        <div class="sr"><span class="sk">Average session quota (5h)</span><span class="sv" id="sAvgEl">--</span></div>
        <div class="sr"><span class="sk">Peak session quota</span><span class="sv" id="sMaxEl">--</span></div>
        <div class="sr"><span class="sk">Average weekly quota (7d)</span><span class="sv" id="wAvgEl">--</span></div>
        <div class="sr"><span class="sk">Peak weekly quota</span><span class="sv" id="wMaxEl">--</span></div>
      </div>
      <div>
        <div class="sr"><span class="sk">Total tokens processed</span><span class="sv" id="totTkEl">--</span></div>
        <div class="sr"><span class="sk">Average tokens per day</span><span class="sv" id="avgDEl">--</span></div>
        <div class="sr"><span class="sk">Record day</span><span class="sv" id="peakDEl">--</span></div>
        <div class="sr"><span class="sk">Days with activity</span><span class="sv" id="actDEl">--</span></div>
      </div>
    </div>
  </div>
</div>

<!-- COSTS -->
<div id="tab-costs" class="panel">
  <div class="sec">
    <div class="st">Estimated cost by session</div>
    <div class="ss">Equivalent cost at API list prices (input + output + cache write 1.25x + cache read 0.1x). Deduplicated by message/request ID. On the Max plan you do not pay per token &mdash; this shows what the usage would be worth on the API.</div>
    <div class="range" style="display:flex;gap:8px;align-items:center;margin:6px 0 10px;flex-wrap:wrap">
      <button class="rtab" data-w="24h" onclick="setCostWindow('24h')">Last 24h</button>
      <button class="rtab active" data-w="7" onclick="setCostWindow(7)">Last 7 days</button>
      <button class="rtab" data-w="30" onclick="setCostWindow(30)">Last 30 days</button>
      <button class="rtab" data-w="all" onclick="setCostWindow('all')">All time</button>
      <input id="costDay" type="date" value="$today" style="background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:4px 8px;font-size:.78rem;color:var(--text);font-family:inherit" onchange="setCostWindow('day')">
      <input id="costFilter" type="text" placeholder="Filter session/project..." style="margin-left:auto;background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:5px 10px;font-size:.78rem;color:var(--text);font-family:inherit" oninput="renderCostTables()">
    </div>
    <div id="tblSessCost"></div>
  </div>
  <div class="sec">
    <div class="st">Estimated cost by project</div>
    <div class="ss">Same estimate, aggregated by project directory across all sessions in the selected window.</div>
    <div id="tblProjCost"></div>
  </div>
</div>

<!-- ANALISI -->
<div id="tab-analisi" class="panel">
  <div class="ss" style="margin-bottom:10px">Stime: la % del limite &egrave; calibrata sul consumo settimanale reale ma approssimata; il ranking relativo &egrave; esatto. I &#36; sono prezzi API pubblici, NON una spesa reale (piano Max).</div>
  <div class="ss" id="aCalibNote" style="display:none;color:var(--orange);margin-bottom:10px">Calibrazione non disponibile: apri Claude Code per aggiornare i rate_limits.</div>
  <div class="rbar">
    <button class="rtab" data-p="24h" onclick="setAnalyticsPeriod('24h')">24h</button>
    <button class="rtab active" data-p="7d" onclick="setAnalyticsPeriod('7d')">7d</button>
    <button class="rtab" data-p="30d" onclick="setAnalyticsPeriod('30d')">30d</button>
    <button class="rtab" data-p="all" onclick="setAnalyticsPeriod('all')">All</button>
  </div>
  <div class="krow">
    <div class="kpi"><div class="kl">Peso periodo<span class="hint" title="Di quanto hai eroso il limite settimanale nel periodo selezionato (stima calibrata sul consumo reale).">&#9432;</span></div><div class="kv blu" id="aK1">--</div><div class="ks" id="aK1s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Cache hit<span class="hint" title="Quota di input gia' servita da cache invece di essere riletta da zero: piu' alta = piu' risparmio automatico.">&#9432;</span></div><div class="kv" id="aK2">--</div><div class="ks">quota input da cache</div></div>
    <div class="kpi"><div class="kl">Tier economico<span class="hint" title="Quota di lavoro (in peso) andata su Sonnet/Haiku invece di Opus/Fable: piu' alta = routing verso i modelli piu' economici sta funzionando.">&#9432;</span></div><div class="kv pur" id="aK3">--</div><div class="ks">quota lavoro su Sonnet/Haiku</div></div>
    <div class="kpi"><div class="kl">Split<span class="hint" title="Come si distribuisce il peso consumato tra input nuovo, output generato e riletture di cache. Se la cache domina, il costo dipende dalla lunghezza delle sessioni, non da quanto scrivi o quanto risponde Claude.">&#9432;</span></div><div id="aSplit">--</div><div class="ks">dove va il peso</div></div>
  </div>
  <div class="sec">
    <div class="st">Per modello</div>
    <div id="tblAModels"></div>
  </div>
  <div class="sec">
    <div class="st">Top sessioni (15)</div>
    <div id="tblASessions"></div>
  </div>
  <div class="sec">
    <div class="st">Per progetto</div>
    <div id="tblAProjects"></div>
  </div>
  <div class="sec">
    <div class="st">Simulatore &quot;E se...&quot;<span class="hint" title="Simula cosa succederebbe al tuo consumo se spostassi il lavoro oggi su Opus verso un modello piu' economico, a parita' di token generati.">&#9432;</span></div>
    <div class="ss">Mix attuale (peso per modello): <span id="aSimMix">--</span></div>
    <div class="rbar">
      <button class="rtab simbtn" data-sim="Sonnet" onclick="simSet('Sonnet')">Tutto l'Opus &rarr; Sonnet</button>
      <button class="rtab simbtn" data-sim="Haiku" onclick="simSet('Haiku')">Tutto l'Opus &rarr; Haiku</button>
      <button class="rtab" onclick="simReset()">Reset</button>
    </div>
    <div id="aSimResult"></div>
  </div>
</div>

<!-- GRAFICI -->
<div id="tab-grafici" class="panel">
  <div class="ss" style="margin-bottom:10px">Andamento nel tempo dei KPI della tab Analisi.</div>
  <div class="rbar">
    <button class="rtab" data-gp="24h" onclick="setGraficiPeriod('24h')">24h</button>
    <button class="rtab active" data-gp="7d" onclick="setGraficiPeriod('7d')">7d</button>
    <button class="rtab" data-gp="30d" onclick="setGraficiPeriod('30d')">30d</button>
    <button class="rtab" data-gp="all" onclick="setGraficiPeriod('all')">All</button>
  </div>
  <div class="sec">
    <div class="st">Peso periodo</div>
    <div id="gPeso"></div>
  </div>
  <div class="sec">
    <div class="st">Cache hit %</div>
    <div id="gCache"></div>
  </div>
  <div class="sec">
    <div class="st">Tier economico %</div>
    <div id="gTier"></div>
  </div>
  <div class="sec">
    <div class="st">Split peso (In / Out / Cache)</div>
    <div id="gSplit"></div>
  </div>
</div>

<script>
var ALL_DATA=[$jsRows];
var DAYS=$jsDays;
var SESSIONS=$jsSessions;
var HOURS=$jsHours;
var SESSCOST=$jsSessCost;
var PROJCOST=$jsProjCost;
var ANALYTICS=$analyticsJson;
var TODAY='$today';
var HAS_LOCAL=$hasLocal;
var STATS={sAvg:$sAvg,sMax:$sMax,wAvg:$wAvg,wMax:$wMax,totalTk:$totalTk,avgDayTk:$avgDayTk,count:$count,peakDate:'$peakDateStr',peakTk:$peakTkVal,weekTk:$weekTk,monthTk:$monthTk,todayTk:$todayTk,yestTk:$yestTk};

function fmtTk(n){if(!n||isNaN(n)||n===0)return '--';if(n>=1e6)return(n/1e6).toFixed(1)+'\u00a0M';if(n>=1000)return Math.round(n/1000)+'\u00a0K';return String(n);}
function fmtD(s){var d=new Date(s+'T12:00:00');return d.toLocaleDateString('en-US',{weekday:'short',month:'2-digit',day:'2-digit'});}
function fmtTs(s){if(!s)return '--';var d=new Date(s);return d.toLocaleString('en-US',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});}
function pct(v){return(v!=null&&v!=='null')?v+'%':'--';}
function g(id){return document.getElementById(id);}
function st(id,v){var e=g(id);if(e)e.textContent=v;}
function barColors(data,mx){return data.map(function(v){var r=mx>0?v/mx:0;return r>=.8?'rgba(239,68,68,.75)':r>=.5?'rgba(245,158,11,.75)':'rgba(59,130,246,.75)';});}
function mkBar(id,labels,data){
  var mx=Math.max.apply(null,data.concat([1]));
  new Chart(g(id).getContext('2d'),{type:'bar',
    data:{labels:labels,datasets:[{label:'Tokens',data:data,backgroundColor:barColors(data,mx),borderRadius:4}]},
    options:{responsive:true,plugins:{legend:{display:false},tooltip:{callbacks:{label:function(c){return' '+fmtTk(c.parsed.y);}}}},
      scales:{x:{ticks:{color:'#888',font:{size:10},maxRotation:0},grid:{display:false}},
              y:{ticks:{color:'#888',callback:function(v){return fmtTk(v);},font:{size:10}},grid:{color:'rgba(128,128,128,.08)'}}}}});
}
function mkDayTable(el,arr){
  if(!arr||!arr.length){el.innerHTML='<div class="nodata">No data available.</div>';return;}
  var h='<table><thead><tr><th>Day</th><th class="num">Tokens</th><th>Models</th></tr></thead><tbody>';
  arr.slice().reverse().forEach(function(d){
    h+='<tr><td>'+fmtD(d.date)+'</td><td class="num"><strong>'+fmtTk(d.total)+'</strong></td><td style="color:#888;font-size:.78rem">'+(d.models||'--')+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}

var inited={};
function switchTab(id){
  document.querySelectorAll('.tab').forEach(function(t){t.classList.toggle('active',t.dataset.tab===id);});
  document.querySelectorAll('.panel').forEach(function(p){p.classList.toggle('active',p.id==='tab-'+id);});
  if(!inited[id]){inited[id]=true;({today:initToday,week:initWeek,month:initMonth,history:initHistory,costs:initCosts,analisi:initAnalytics,grafici:initGrafici})[id]();}
}

function initToday(){
  st('kT1',fmtTk(STATS.todayTk));
  if(STATS.todayTk&&STATS.yestTk){
    var p=Math.round((STATS.todayTk-STATS.yestTk)/STATS.yestTk*100);
    var el=g('kT2');if(el){el.textContent=(p>0?'+':'')+p+'%';el.className='kv '+(p>0?'up':p<0?'dn':'');}
    st('kT2s','vs yesterday ('+fmtTk(STATS.yestTk)+')');
  }else{st('kT2','--');st('kT2s','no yesterday data');}
  st('kT1s',STATS.todayTk?'yesterday: '+fmtTk(STATS.yestTk):'');
  var maxV=0,maxH=0;
  HOURS.forEach(function(v,i){if(v>maxV){maxV=v;maxH=i;}});
  st('kT4',maxV>0?maxH+':00':'--');
  st('kT4s',maxV>0?fmtTk(maxV)+' tokens':'no activity');
  var todaySess=SESSIONS.filter(function(s){return s.lastTs&&new Date(s.lastTs).toISOString().slice(0,10)===TODAY;});
  st('kT3',String(todaySess.length));
  mkBar('cHour',HOURS.map(function(_,i){return i+':00';}),HOURS);
  var el=g('tblToday');
  if(!todaySess.length){el.innerHTML='<div class="nodata">No sessions active today.</div>';return;}
  var h='<table><thead><tr><th>Session</th><th class="num">Tokens</th><th>Last active</th></tr></thead><tbody>';
  todaySess.forEach(function(s){h+='<tr><td>Session\u00a0'+s.n+'</td><td class="num"><strong>'+fmtTk(s.total)+'</strong></td><td style="color:#888">'+fmtTs(s.lastTs)+'</td></tr>';});
  el.innerHTML=h+'</tbody></table>';
}

function initWeek(){
  var cut=new Date(Date.now()-6*864e5).toISOString().slice(0,10);
  var wd=DAYS.filter(function(d){return d.date>=cut;});
  var wt=STATS.weekTk;
  var act=wd.filter(function(d){return d.total>0;}).length;
  var pk=wd.reduce(function(a,b){return(b.total||0)>(a.total||0)?b:a;},{total:0,date:''});
  var avg=wd.length?Math.round(wt/wd.length):0;
  st('kW1',fmtTk(wt));st('kW2',act+' / 7');
  st('kW3',pk.date?fmtD(pk.date):'--');st('kW3s',pk.date?fmtTk(pk.total):'');
  st('kW4',fmtTk(avg));
  mkBar('cWeek',wd.map(function(d){return fmtD(d.date);}),wd.map(function(d){return d.total||0;}));
  mkDayTable(g('tblWeek'),wd);
}

function initMonth(){
  var mp=TODAY.slice(0,7);
  var md=DAYS.filter(function(d){return d.date.slice(0,7)===mp;});
  var mt=STATS.monthTk;
  var act=md.filter(function(d){return d.total>0;}).length;
  var pk=md.reduce(function(a,b){return(b.total||0)>(a.total||0)?b:a;},{total:0,date:''});
  var avg=md.length?Math.round(mt/md.length):0;
  var mLabel=new Date(mp+'-15').toLocaleDateString('en-US',{month:'long',year:'numeric'});
  st('kM1',fmtTk(mt));st('kM1s',mLabel);
  st('kM2',act+' days');
  st('kM3',pk.date?fmtD(pk.date):'--');st('kM3s',pk.date?fmtTk(pk.total):'');
  st('kM4',fmtTk(avg));
  mkBar('cMonth',md.map(function(d){return fmtD(d.date);}),md.map(function(d){return d.total||0;}));
  mkDayTable(g('tblMonth'),md);
}

var cUsageChart=null;
function setRange(days){
  var rTabs=document.querySelectorAll('.rtab');
  rTabs.forEach(function(t,i){t.classList.toggle('active',[1,7,30][i]===days);});
  if(!cUsageChart)return;
  var cut=new Date(Date.now()-days*864e5);
  var rows=days>=30?ALL_DATA:ALL_DATA.filter(function(d){return d.ts&&new Date(d.ts)>=cut;});
  var info=g('rInfo');
  if(!rows.length){if(info)info.textContent='No data in this period';cUsageChart.data.datasets.forEach(function(ds){ds.data=[];});cUsageChart.update();return;}
  var x0=rows[0].ts,x1=rows[rows.length-1].ts;
  cUsageChart.data.datasets[0].data=rows.map(function(d){return{x:d.ts,y:d.sess};});
  cUsageChart.data.datasets[1].data=rows.map(function(d){return{x:d.ts,y:d.week};});
  cUsageChart.data.datasets[2].data=[{x:x0,y:80},{x:x1,y:80}];
  cUsageChart.data.datasets[3].data=[{x:x0,y:95},{x:x1,y:95}];
  cUsageChart.update();
  var f=new Date(rows[0].ts).toLocaleDateString('en-US',{month:'2-digit',day:'2-digit'});
  var t2=new Date(rows[rows.length-1].ts).toLocaleDateString('en-US',{month:'2-digit',day:'2-digit'});
  if(info)info.textContent=rows.length+' measurements'+(f!==t2?' ('+f+' to '+t2+')':'');
}

function initHistory(){
  st('kH1',fmtTk(STATS.totalTk));
  if(STATS.peakDate){st('kH2',fmtD(STATS.peakDate));st('kH2s',fmtTk(STATS.peakTk));}
  st('kH3',fmtTk(STATS.avgDayTk));st('kH3s',DAYS.length+' days avg');
  st('kH4',pct(STATS.sAvg));
  st('sAvgEl',pct(STATS.sAvg));st('sMaxEl',pct(STATS.sMax));
  st('wAvgEl',pct(STATS.wAvg));st('wMaxEl',pct(STATS.wMax));
  st('totTkEl',fmtTk(STATS.totalTk));st('avgDEl',fmtTk(STATS.avgDayTk));
  if(STATS.peakDate)st('peakDEl',fmtD(STATS.peakDate)+' \u2014 '+fmtTk(STATS.peakTk));
  st('actDEl',DAYS.length+' days');
  var sel=g('tblSess');
  if(!SESSIONS.length){sel.innerHTML='<div class="nodata">No session data.</div>';}
  else{
    var h='<table><thead><tr><th>Session</th><th class="num">Tokens</th><th>Last active</th></tr></thead><tbody>';
    SESSIONS.forEach(function(s){h+='<tr><td>Session\u00a0'+s.n+'</td><td class="num"><strong>'+fmtTk(s.total)+'</strong></td><td style="color:#888">'+fmtTs(s.lastTs)+'</td></tr>';});
    sel.innerHTML=h+'</tbody></table>';
  }
  mkDayTable(g('tblAll'),DAYS);
  var ctxU=g('cUsage').getContext('2d');
  cUsageChart=new Chart(ctxU,{type:'line',data:{datasets:[
    {label:'Session 5h',borderColor:'#d97706',backgroundColor:'rgba(217,119,6,.07)',pointRadius:2,pointHoverRadius:5,tension:.3,yAxisID:'y',data:[]},
    {label:'Weekly 7d',borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,.07)',pointRadius:2,pointHoverRadius:5,tension:.3,yAxisID:'y',data:[]},
    {label:'Warning 80%',borderColor:'rgba(245,158,11,.4)',borderDash:[6,4],pointRadius:0,fill:false,yAxisID:'y',data:[]},
    {label:'Critical 95%',borderColor:'rgba(239,68,68,.45)',borderDash:[3,3],pointRadius:0,fill:false,yAxisID:'y',data:[]}
  ]},options:{responsive:true,interaction:{mode:'index',intersect:false},
    plugins:{legend:{display:false},tooltip:{callbacks:{
      title:function(it){return new Date(it[0].parsed.x).toLocaleString('en-US',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});},
      label:function(it){if(it.datasetIndex>=2)return null;return'  '+it.dataset.label+': '+(it.parsed.y!=null?it.parsed.y.toFixed(1)+'%':'N/A');},
      filter:function(it){return it.datasetIndex<2;}
    }}},
    scales:{
      x:{type:'time',time:{tooltipFormat:'MM/dd HH:mm'},ticks:{color:'#888',maxRotation:0,font:{size:11}},grid:{color:'rgba(128,128,128,.07)'}},
      y:{min:0,max:100,ticks:{color:'#888',callback:function(v){return v+'%';},font:{size:11}},grid:{color:'rgba(128,128,128,.07)'}}
    }
  }});
  setRange(1);
}

var COST_WINDOW=7;
function costWindowKeys(){
  if(COST_WINDOW==='24h')return{t:'t_24h',m:'m_24h'};
  if(COST_WINDOW===7)return{t:'t_7',m:'m_7'};
  if(COST_WINDOW===30)return{t:'t_30',m:'m_30'};
  if(COST_WINDOW==='day')return null;
  return{t:'t_all',m:'m_all'};
}
function mkCostTable(el,arr,kind,filterText){
  var k=costWindowKeys();
  var rows=arr.map(function(r){
    if(COST_WINDOW==='day'){
      var day=(g('costDay')&&g('costDay').value)||'';
      var d=(r.byDay&&day&&r.byDay[day])||{t:0,m:[]};
      return{r:r,total:d.t,models:d.m};
    }
    return{r:r,total:r[k.t],models:r[k.m]};
  }).filter(function(x){return x.total>0;});
  if(filterText){
    var ft=filterText.toLowerCase();
    rows=rows.filter(function(x){
      var hay=(kind==='sid'?(x.r.sid+' '+(x.r.proj||'')):x.r.name).toLowerCase();
      return hay.indexOf(ft)>=0;
    });
  }
  rows.sort(function(a,b){return b.total-a.total;});
  if(!rows.length){el.innerHTML='<div class="nodata">No cost data for this window.</div>';return;}
  var h='<table><thead><tr><th>'+(kind==='sid'?'Session':'Project')+'</th><th class="num">Est. cost</th><th>By model</th><th>Last active</th></tr></thead><tbody>';
  rows.forEach(function(x){
    var r=x.r;
    var parts=x.models.map(function(m){return m.m+' <strong>'+'&#36;'+m.c.toFixed(2)+'</strong>';}).join(' &middot; ');
    var lbl=(kind==='sid')?((r.title?r.title:('Session&nbsp;'+r.sid))+(r.proj?(' <span style="color:#888">&middot; '+r.proj+'</span>'):'')):r.name;
    h+='<tr><td>'+lbl+'</td><td class="num"><strong>'+'&#36;'+x.total.toFixed(2)+'</strong></td><td style="color:#888">'+parts+'</td><td style="color:#888">'+fmtTs(r.lastTs)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}
function renderCostTables(){
  var ft=(g('costFilter')&&g('costFilter').value)||'';
  mkCostTable(g('tblSessCost'),SESSCOST,'sid',ft);
  mkCostTable(g('tblProjCost'),PROJCOST,'proj',ft);
}
function setCostWindow(w){
  COST_WINDOW=w;
  document.querySelectorAll('#tab-costs .rtab').forEach(function(t){t.classList.toggle('active',t.dataset.w==(''+w));});
  renderCostTables();
}
function initCosts(){
  renderCostTables();
}
var AN_PERIOD='7d';
var AN_SIM=null;
var AN_PRICES={
  Opus:{pin:15,pout:75,rin:5,rout:25},
  Sonnet:{pin:3,pout:15,rin:3,rout:15},
  Haiku:{pin:0.80,pout:4,rin:1,rout:5},
  Fable:{pin:15,pout:75,rin:10,rout:50}
};
function fmtN2(v){return(v==null||isNaN(v))?'-':Number(v).toFixed(2);}
function fmtP1(v){return(v==null||isNaN(v))?'-':Number(v).toFixed(1)+'%';}

function setAnalyticsPeriod(p){
  AN_PERIOD=p;
  document.querySelectorAll('#tab-analisi .rbar .rtab').forEach(function(t){if(t.dataset.p)t.classList.toggle('active',t.dataset.p===p);});
  renderAnalytics();
}
function initAnalytics(){renderAnalytics();}
function renderAnalytics(){
  var d=ANALYTICS[AN_PERIOD];
  if(!d)return;
  var calib=ANALYTICS.calib;
  var note=g('aCalibNote');
  if(note)note.style.display=calib.valid?'none':'block';
  st('aK1',calib.valid?('≈'+fmtP1(d.totals.estPct)):'-');
  st('aK1s','peso '+fmtN2(d.totals.peso)+' · $'+fmtN2(d.totals.usd));
  var chEl=g('aK2');if(chEl){chEl.textContent=fmtP1(d.totals.cacheHitPct);chEl.className='kv '+(d.totals.cacheHitPct>70?'grn':'');}
  st('aK3',fmtP1(d.totals.cheapTierPct));
  var pin=d.totals.pesoInPct||0,pout=d.totals.pesoOutPct||0,pc=d.totals.pesoCachePct||0;
  var splitEl=g('aSplit');
  if(splitEl){
    splitEl.innerHTML='<div style="display:flex;height:10px;border-radius:4px;overflow:hidden;background:var(--bg3)"><div style="width:'+pin.toFixed(1)+'%;background:#3b82f6"></div><div style="width:'+pout.toFixed(1)+'%;background:#f59e0b"></div><div style="width:'+pc.toFixed(1)+'%;background:#a855f7"></div></div><div style="font-size:.68rem;color:#888;margin-top:4px">In '+pin.toFixed(0)+'% · Out '+pout.toFixed(0)+'% · Cache '+pc.toFixed(0)+'%</div>';
  }
  renderModelsTable(d);
  renderSessionsTable(d);
  renderProjectsTable(d);
  renderSimulator(d);
}
function renderModelsTable(d){
  var el=g('tblAModels');
  if(!d.models.length){el.innerHTML='<div class="nodata">No data.</div>';return;}
  var h='<table><thead><tr><th>Modello</th><th class="num">Peso rel.<span class="hint" title="Moltiplicatore di peso rispetto ad Haiku (1x): Opus pesa 5 volte un token Haiku, Fable 10 volte.">&#9432;</span></th><th class="num">Input</th><th class="num">Output</th><th class="num">Cache(read)</th><th class="num">Peso</th><th class="num">% limite<span class="hint" title="Stima di quanto quella riga pesa sul limite settimanale del piano. Il numero assoluto e\' approssimato, il confronto tra righe e\' affidabile.">&#9432;</span></th><th class="num">$<span class="hint" title="Costo stimato come se pagassi a consumo via API: NON e\' una spesa reale sul piano Max, e\' solo un riferimento di scala.">&#9432;</span></th><th class="num">Share%</th></tr></thead><tbody>';
  d.models.forEach(function(m){
    h+='<tr><td>'+m.name+'</td><td class="num">'+m.tierLabel+'</td><td class="num">'+fmtTk(m.input)+'</td><td class="num">'+fmtTk(m.output)+'</td><td class="num">'+fmtTk(m.cacheRead)+'</td><td class="num">'+fmtN2(m.peso)+'</td><td class="num">'+(m.estPct!=null?fmtP1(m.estPct):'-')+'</td><td class="num">$'+fmtN2(m.usd)+'</td><td class="num">'+fmtP1(m.share)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}
function renderSessionsTable(d){
  var el=g('tblASessions');
  if(!d.sessions.length){el.innerHTML='<div class="nodata">No data.</div>';return;}
  var h='<table><thead><tr><th>Sessione</th><th>Progetto</th><th>Modelli</th><th class="num">Peso</th><th class="num">% limite<span class="hint" title="Stima di quanto quella riga pesa sul limite settimanale del piano. Il numero assoluto e\' approssimato, il confronto tra righe e\' affidabile.">&#9432;</span></th><th class="num">$<span class="hint" title="Costo stimato come se pagassi a consumo via API: NON e\' una spesa reale sul piano Max, e\' solo un riferimento di scala.">&#9432;</span></th><th>Apri</th></tr></thead><tbody>';
  d.sessions.forEach(function(s,i){
    var fid=encodeURIComponent(s.fullId||'');
    var openLinks='<a href="http://100.110.76.42:5000/chat/'+fid+'" target="_blank" title="Apri in Friday" style="text-decoration:none;margin-left:6px;opacity:.7" onclick="event.stopPropagation()">🌐</a>'+
      '<a href="claude://resume?session='+fid+'" title="Riprendi in Claude Desktop" style="text-decoration:none;margin-left:6px;opacity:.7" onclick="event.stopPropagation()">💬</a>';
    h+='<tr class="sessRow" style="cursor:pointer" onclick="toggleSessDetail('+i+')"><td><span id="sessArrow'+i+'" style="display:inline-block;width:1em;color:#888">&#9656;</span>'+s.id+'</td><td>'+(s.project||'--')+'</td><td style="color:#888;font-size:.78rem">'+s.models.join(', ')+'</td><td class="num">'+fmtN2(s.peso)+'</td><td class="num">'+(s.estPct!=null?fmtP1(s.estPct):'-')+'</td><td class="num">$'+fmtN2(s.usd)+'</td><td>'+openLinks+'</td></tr>';
    h+='<tr class="sessDetailRow" id="sessDetail'+i+'" style="display:none"><td colspan="7" style="padding:0">'+renderSessDetailHtml(s)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}
function renderSessDetailHtml(s){
  var md=s.modelDetail||[];
  if(!md.length){return '<div class="nodata" style="margin:6px 24px">Nessun dettaglio.</div>';}
  var h='<table style="margin:6px 0 6px 24px;width:calc(100% - 24px);background:var(--bg3)"><thead><tr><th>Modello</th><th class="num">Peso rel.</th><th class="num">Input</th><th class="num">Output</th><th class="num">Cache(read)</th><th class="num">Peso</th><th class="num">% limite</th><th class="num">$</th><th class="num">Share%</th></tr></thead><tbody>';
  md.forEach(function(m){
    h+='<tr><td>'+m.name+'</td><td class="num">'+m.tierLabel+'</td><td class="num">'+fmtTk(m.input)+'</td><td class="num">'+fmtTk(m.output)+'</td><td class="num">'+fmtTk(m.cacheRead)+'</td><td class="num">'+fmtN2(m.peso)+'</td><td class="num">'+(m.estPct!=null?fmtP1(m.estPct):'-')+'</td><td class="num">$'+fmtN2(m.usd)+'</td><td class="num">'+fmtP1(m.share)+'</td></tr>';
  });
  return h+'</tbody></table>';
}
function toggleSessDetail(i){
  var row=g('sessDetail'+i);
  var arrow=g('sessArrow'+i);
  if(!row)return;
  var show=row.style.display==='none';
  row.style.display=show?'table-row':'none';
  if(arrow)arrow.innerHTML=show?'&#9662;':'&#9656;';
}
function renderProjectsTable(d){
  var el=g('tblAProjects');
  if(!d.projects.length){el.innerHTML='<div class="nodata">No data.</div>';return;}
  var h='<table><thead><tr><th>Progetto</th><th>Modelli</th><th class="num">Peso</th><th class="num">% limite<span class="hint" title="Stima di quanto quella riga pesa sul limite settimanale del piano. Il numero assoluto e\' approssimato, il confronto tra righe e\' affidabile.">&#9432;</span></th><th class="num">$<span class="hint" title="Costo stimato come se pagassi a consumo via API: NON e\' una spesa reale sul piano Max, e\' solo un riferimento di scala.">&#9432;</span></th></tr></thead><tbody>';
  d.projects.forEach(function(p){
    h+='<tr><td>'+p.name+'</td><td style="color:#888;font-size:.78rem">'+p.models.join(', ')+'</td><td class="num">'+fmtN2(p.peso)+'</td><td class="num">'+(p.estPct!=null?fmtP1(p.estPct):'-')+'</td><td class="num">$'+fmtN2(p.usd)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}
function calcModelUsdPeso(tier,inp,out,cr,c5,c1){
  var p=AN_PRICES[tier];
  var usd=(inp*p.pin+out*p.pout+cr*p.pin*0.10+c5*p.pin*1.25+c1*p.pin*2.00)/1e6;
  var peso=(inp*p.rin+out*p.rout+cr*p.rin*0.10+c5*p.rin*1.25+c1*p.rin*2.00)/1e6;
  return{usd:usd,peso:peso};
}
function renderSimulator(d){
  var mixEl=g('aSimMix');
  if(mixEl)mixEl.innerHTML=d.models.map(function(m){return m.name+': '+fmtN2(m.peso);}).join(' &middot; ')||'--';
  var resEl=g('aSimResult');
  if(!resEl)return;
  var opus=d.models.find(function(m){return m.name==='Opus';});
  var calib=ANALYTICS.calib;
  // Baseline ricalcolato con la stessa formula del backend (split cache 5m/1h) cosi'
  // da coincidere con ANALYTICS[periodo].totals.peso ed evitare delta fasulli.
  var baseline=d.models.reduce(function(acc,m){
    var r=calcModelUsdPeso(m.name,m.input,m.output,m.cacheRead,m.cacheCreate5m,m.cacheCreate1h);
    acc.peso+=r.peso;acc.usd+=r.usd;return acc;
  },{peso:0,usd:0});
  var baseEstPct=calib.valid?(baseline.peso*calib.K):null;
  if(!AN_SIM||!opus){
    resEl.innerHTML='<div class="ss">Nessuna simulazione attiva. Peso attuale: '+fmtN2(baseline.peso)+' &middot; $'+fmtN2(baseline.usd)+(calib.valid?(' &middot; '+fmtP1(baseEstPct)):'')+'</div>';
    return;
  }
  var opusCalc=calcModelUsdPeso('Opus',opus.input,opus.output,opus.cacheRead,opus.cacheCreate5m,opus.cacheCreate1h);
  var sim=calcModelUsdPeso(AN_SIM,opus.input,opus.output,opus.cacheRead,opus.cacheCreate5m,opus.cacheCreate1h);
  var newTotalPeso=baseline.peso-opusCalc.peso+sim.peso;
  var newTotalUsd=baseline.usd-opusCalc.usd+sim.usd;
  var deltaPeso=newTotalPeso-baseline.peso;
  var deltaPct=baseline.peso?(deltaPeso/baseline.peso*100):0;
  var newEstPct=calib.valid?(newTotalPeso*calib.K):null;
  resEl.innerHTML=
    '<div class="ss">Simulazione: Opus &rarr; '+AN_SIM+'</div>'+
    '<div class="sr"><span class="sk">Peso attuale</span><span class="sv">'+fmtN2(baseline.peso)+'</span></div>'+
    '<div class="sr"><span class="sk">Peso simulato</span><span class="sv">'+fmtN2(newTotalPeso)+'</span></div>'+
    '<div class="sr"><span class="sk">&Delta; peso</span><span class="sv '+(deltaPeso<0?'dn':'up')+'">'+(deltaPeso>=0?'+':'')+fmtN2(deltaPeso)+' ('+(deltaPct>=0?'+':'')+deltaPct.toFixed(1)+'%)</span></div>'+
    '<div class="sr"><span class="sk">$ attuale &rarr; simulato</span><span class="sv">$'+fmtN2(baseline.usd)+' &rarr; $'+fmtN2(newTotalUsd)+'</span></div>'+
    (calib.valid?('<div class="sr"><span class="sk">% limite attuale &rarr; simulato</span><span class="sv">'+fmtP1(baseEstPct)+' &rarr; '+fmtP1(newEstPct)+'</span></div>'):'');
}
function simSet(target){
  AN_SIM=target;
  document.querySelectorAll('#tab-analisi .simbtn').forEach(function(b){b.classList.toggle('active',b.dataset.sim===target);});
  renderSimulator(ANALYTICS[AN_PERIOD]);
}
function simReset(){
  AN_SIM=null;
  document.querySelectorAll('#tab-analisi .simbtn').forEach(function(b){b.classList.remove('active');});
  renderSimulator(ANALYTICS[AN_PERIOD]);
}

function pathFromPts(pts){
  return pts.map(function(p,i){return(i===0?'M':'L')+p.x.toFixed(1)+','+p.y.toFixed(1);}).join(' ');
}
function weightedMovingAvg(data,valueKey,windowRadius){
  return data.map(function(d,i){
    var lo=Math.max(0,i-windowRadius),hi=Math.min(data.length-1,i+windowRadius);
    var sumW=0,sumWV=0;
    for(var j=lo;j<=hi;j++){
      var w=data[j].peso>0?data[j].peso:0.001;
      sumW+=w;sumWV+=w*data[j][valueKey];
    }
    return sumW>0?sumWV/sumW:data[i][valueKey];
  });
}
function ptsFromValues(values,min,max,W,H,padL,padR,padT,padB){
  var n=values.length;
  var xStep=(W-padL-padR)/(n-1);
  return values.map(function(v,i){
    var x=padL+i*xStep;
    var y=padT+(H-padT-padB)*(1-((v-min)/((max-min)||1)));
    return{x:x,y:y,v:v};
  });
}
function renderLineChart(containerId,data,opts){
  var el=g(containerId);
  if(!el)return;
  if(!data||data.length<2){el.innerHTML='<div class="nodata">Dati insufficienti per il grafico in questo periodo.</div>';return;}
  var key=opts.yKey,color=opts.color||'#3b82f6';
  var vals=data.map(function(d){return d[key]==null?0:d[key];});
  var lineVals=opts.weightByPeso?weightedMovingAvg(data,key,1):vals;
  var dataMin=Math.min.apply(null,lineVals),dataMax=Math.max.apply(null,lineVals);
  var range=(dataMax-dataMin)||dataMax||1;
  var margin=range*0.1;
  var min=dataMin-margin,max=dataMax+margin;
  if(opts.pct){min=Math.max(0,min);max=Math.min(100,max);}
  else{min=Math.max(0,min);}
  if(max===min)max=min+1;
  var rawMin=Math.min.apply(null,vals),rawMax=Math.max.apply(null,vals);
  if(rawMin<min)min=rawMin;
  if(rawMax>max)max=rawMax;
  if(opts.pct){min=Math.max(0,min);max=Math.min(100,max);}
  if(max===min)max=min+1;
  var W=600,H=150,padL=42,padR=10,padT=10,padB=22;
  var pts=ptsFromValues(lineVals,min,max,W,H,padL,padR,padT,padB);
  var rawPts=ptsFromValues(vals,min,max,W,H,padL,padR,padT,padB);
  var linePath=pathFromPts(pts);
  var areaPts=[{x:pts[0].x,y:H-padB}].concat(pts).concat([{x:pts[pts.length-1].x,y:H-padB}]);
  var areaPath=pathFromPts(areaPts)+' Z';
  var pesoMax=opts.weightByPeso?Math.max.apply(null,data.map(function(d){return d.peso==null?0:d.peso;})):0;
  var circles=rawPts.map(function(p,i){
    var r=2.3,fo=1;
    if(opts.weightByPeso){
      var vol=data[i].peso==null?0:data[i].peso;
      var volRatio=pesoMax>0?(vol/pesoMax):1;
      r=1.5+volRatio*2.5;
      fo=0.25+volRatio*0.75;
    }
    return'<circle cx="'+p.x.toFixed(1)+'" cy="'+p.y.toFixed(1)+'" r="'+r.toFixed(2)+'" fill="'+color+'" fill-opacity="'+fo.toFixed(2)+'"><title>'+data[i].label+': '+p.v+(opts.weightByPeso?' (peso '+(data[i].peso==null?0:data[i].peso)+')':'')+'</title></circle>';
  }).join('');
  var svg='<svg viewBox="0 0 '+W+' '+H+'" style="width:100%;height:150px;display:block">'+
    '<line x1="'+padL+'" y1="'+padT+'" x2="'+padL+'" y2="'+(H-padB)+'" stroke="#3a3a3a"/>'+
    '<line x1="'+padL+'" y1="'+(H-padB)+'" x2="'+(W-padR)+'" y2="'+(H-padB)+'" stroke="#3a3a3a"/>'+
    '<path d="'+areaPath+'" fill="'+color+'" opacity="0.15"/>'+
    '<path d="'+linePath+'" fill="none" stroke="'+color+'" stroke-width="2"/>'+
    circles+
    '<text x="2" y="'+(padT+8)+'" font-size="9" fill="#888">'+max.toFixed(1)+'</text>'+
    '<text x="2" y="'+(H-padB)+'" font-size="9" fill="#888">'+min.toFixed(1)+'</text>'+
    '<text x="'+padL+'" y="'+(H-4)+'" font-size="9" fill="#888">'+data[0].label+'</text>'+
    '<text x="'+(W-padR)+'" y="'+(H-4)+'" font-size="9" fill="#888" text-anchor="end">'+data[data.length-1].label+'</text>'+
    '</svg>';
  el.innerHTML=svg;
}
function renderStackedChart(containerId,data,series){
  var el=g(containerId);
  if(!el)return;
  if(!data||data.length<2){el.innerHTML='<div class="nodata">Dati insufficienti per il grafico in questo periodo.</div>';return;}
  var W=600,H=150,padL=10,padR=10,padT=10,padB=22;
  var n=data.length;
  var xStep=(W-padL-padR)/(n-1);
  var cum=data.map(function(){return 0;});
  var paths='';
  series.forEach(function(s){
    var top=[],bottom=[];
    data.forEach(function(d,i){
      var v=d[s.key]==null?0:d[s.key];
      var x=padL+i*xStep;
      var y0=H-padB-(H-padT-padB)*(cum[i]/100);
      cum[i]+=v;
      var y1=H-padB-(H-padT-padB)*(cum[i]/100);
      top.push({x:x,y:y1});
      bottom.push({x:x,y:y0});
    });
    var d2=pathFromPts(top.concat(bottom.slice().reverse()))+' Z';
    paths+='<path d="'+d2+'" fill="'+s.color+'" opacity="0.78"/>';
  });
  var legend=series.map(function(s){return'<span class="dot" style="background:'+s.color+'"></span>'+s.label;}).join(' &nbsp; ');
  var svg='<svg viewBox="0 0 '+W+' '+H+'" style="width:100%;height:150px;display:block">'+
    '<line x1="'+padL+'" y1="'+(H-padB)+'" x2="'+(W-padR)+'" y2="'+(H-padB)+'" stroke="#3a3a3a"/>'+
    paths+
    '<text x="'+padL+'" y="'+(H-4)+'" font-size="9" fill="#888">'+data[0].label+'</text>'+
    '<text x="'+(W-padR)+'" y="'+(H-4)+'" font-size="9" fill="#888" text-anchor="end">'+data[data.length-1].label+'</text>'+
    '</svg>';
  el.innerHTML=svg+'<div class="legend">'+legend+'</div>';
}
var GN_PERIOD='7d';
function setGraficiPeriod(p){
  GN_PERIOD=p;
  document.querySelectorAll('#tab-grafici .rbar .rtab').forEach(function(t){if(t.dataset.gp)t.classList.toggle('active',t.dataset.gp===p);});
  renderGrafici();
}
function initGrafici(){renderGrafici();}
function renderGrafici(){
  var d=ANALYTICS[GN_PERIOD];
  if(!d)return;
  var trend=d.trend||[];
  var calib=ANALYTICS.calib;
  var pesoKey=calib.valid?'estPct':'peso';
  renderLineChart('gPeso',trend,{yKey:pesoKey,color:'#3b82f6',label:calib.valid?'% limite':'peso'});
  renderLineChart('gCache',trend,{yKey:'cacheHitPct',pct:true,weightByPeso:true,color:'#22c55e'});
  renderLineChart('gTier',trend,{yKey:'cheapTierPct',pct:true,weightByPeso:true,color:'#a855f7'});
  renderStackedChart('gSplit',trend,[
    {key:'pesoInPct',color:'#3b82f6',label:'In'},
    {key:'pesoOutPct',color:'#f59e0b',label:'Out'},
    {key:'pesoCachePct',color:'#a855f7',label:'Cache'}
  ]);
}

inited['today']=true;
initToday();
</script>
</body>
</html>
"@

    $htmlPath = Join-Path $env:TEMP "claude-usage-dashboard.html"
    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.Encoding]::UTF8)
    # explorer.exe apre il file nel contesto della shell utente:
    # funziona anche se il tray gira in un contesto ristretto
    Start-Process explorer.exe -ArgumentList "`"$htmlPath`""
  } catch {
    "$([datetime]::Now) Show-HistoryChart ERRORE: $_`n$($_.ScriptStackTrace)" | Out-File $LogFile -Append -Encoding UTF8
  }
}
# ─── Credenziali ──────────────────────────────────────────────────────────────
function Get-Credentials {
    $all = Read-JsonFile $CredFile
    if (-not $all) { return $null }
    return $all.claudeAiOauth
}

# ─── Refresh token ────────────────────────────────────────────────────────────
function Invoke-TokenRefresh([bool]$force = $false) {
    $creds = Get-Credentials
    if (-not $creds -or -not $creds.refreshToken) { return $creds }
    $now = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    if (-not $force -and $creds.expiresAt -gt ($now + 60000)) { return $creds }
    if (-not $force) {
        $fresh = Get-Credentials
        if ($fresh -and $fresh.accessToken -ne $creds.accessToken) { return $fresh }
        if ($fresh -and $fresh.expiresAt -gt ($now + 60000)) { return $fresh }
    }
    try {
        $body = "grant_type=refresh_token&refresh_token=$([System.Uri]::EscapeDataString($creds.refreshToken))&client_id=$ClientId"
        $resp = Invoke-WebRequest `
            -Uri "https://api.anthropic.com/v1/oauth/token" `
            -Method Post -ContentType "application/x-www-form-urlencoded" `
            -Headers @{ "User-Agent"="claude-code/2.1.78"; "anthropic-beta"="oauth-2025-04-20" } `
            -Body $body -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
        $all  = Read-JsonFile $CredFile
        $nowMs= [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
        $all.claudeAiOauth.accessToken  = $data.access_token
        $all.claudeAiOauth.refreshToken = $data.refresh_token
        $all.claudeAiOauth.expiresAt    = $nowMs + ([long]$data.expires_in * 1000L)
        Write-JsonFile $CredFile $all
        return $all.claudeAiOauth
    } catch { return $creds }
}

# ─── Cache stdin (Claude Code status line) ────────────────────────────────────
$RateLimitCacheFile = Join-Path $env:USERPROFILE ".claude\rate-limits-cache.json"
function Get-StdinCache {
    if (-not (Test-Path $RateLimitCacheFile)) { return $null }
    try {
        $c = Read-JsonFile $RateLimitCacheFile
        if (-not $c -or -not $c.cached_at) { return $null }
        $nowUnix = [long]([datetime]::UtcNow - [datetime]::new(1970,1,1,0,0,0,'Utc')).TotalSeconds
        if (($nowUnix - [long]$c.cached_at) -gt 600) { return $null }  # stale oltre 10 min
        return $c
    } catch { return $null }
}

# ─── API usage ────────────────────────────────────────────────────────────────
function Get-UsageStats {
    param([bool]$retried = $false)
    $result = [ordered]@{
        Session     = [ordered]@{}
        Week        = [ordered]@{}
        Model       = [ordered]@{}
        ExtraUsage  = $false
        Error       = ""
        LastUpdated = (Get-Date)
    }
    # Priorità 1: cache stdin da Claude Code (zero OAuth calls)
    if (-not $retried) {
        $sc = Get-StdinCache
        if ($sc) {
            $result.Session = [ordered]@{
                Utilization = [math]::Round([double]$sc.five_hour.used_percentage, 1)
                ResetsAt    = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$sc.five_hour.resets_at).LocalDateTime
            }
            $result.Week = [ordered]@{
                Utilization = [math]::Round([double]$sc.seven_day.used_percentage, 1)
                ResetsAt    = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$sc.seven_day.resets_at).LocalDateTime
            }
            $result["Source"] = "live"
            # La cache stdin non ha il limite per-modello: riusa l'ultimo noto
            if ($script:LastGoodStats -and $script:LastGoodStats.Model -and $null -ne $script:LastGoodStats.Model.Utilization) {
                $result.Model = $script:LastGoodStats.Model
            }
            $script:LastGoodStats = $result
            $script:LastFreshTime = Get-Date
            $script:LoginNeeded   = $false
            Save-HistoryEntry $result
            return $result
        }
    }
    # Priorità 2: cooldown cache OAuth
    $elapsed = ((Get-Date) - $script:LastCallTime).TotalSeconds
    if (-not $retried -and $elapsed -lt $CooldownSec -and $script:LastGoodStats) {
        $cached = [ordered]@{}
        foreach ($k in $script:LastGoodStats.Keys) { $cached[$k] = $script:LastGoodStats[$k] }
        $cached["Cached"] = $true; $cached["LastUpdated"] = Get-Date
        return $cached
    }
    $script:LastCallTime = Get-Date
    try {
        $creds = Invoke-TokenRefresh
        if (-not $creds -or -not $creds.accessToken) { $result.Error = "Nessun token trovato"; $script:LoginNeeded = $true; return $result }
        $resp = Invoke-WebRequest `
            -Uri "https://api.anthropic.com/api/oauth/usage" `
            -Method Get `
            -Headers @{
                "Authorization"  = "Bearer $($creds.accessToken)"
                "Content-Type"   = "application/json"
                "User-Agent"     = "claude-code/2.1.78"
                "anthropic-beta" = "oauth-2025-04-20"
            } -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
        if ($data.five_hour) {
            $result.Session = [ordered]@{
                Utilization = [math]::Round([double]$data.five_hour.utilization,1)
                ResetsAt    = Parse-IsoDate $data.five_hour.resets_at
            }
        }
        if ($data.seven_day) {
            $result.Week = [ordered]@{
                Utilization = [math]::Round([double]$data.seven_day.utilization,1)
                ResetsAt    = Parse-IsoDate $data.seven_day.resets_at
            }
        }
        # Risposta 200 ma senza dati utilizzabili (visto in pratica: five_hour/seven_day
        # presenti ma con resets_at nullo, o assenti del tutto) - NON e' un successo:
        # tratta come fallimento cosi' il ramo sotto ricade sulla cache invece di
        # sovrascriverla con zeri.
        if (-not $result.Session.ResetsAt -or -not $result.Week.ResetsAt) {
            throw "Risposta API incompleta (five_hour/seven_day senza resets_at)"
        }
        if ($data.extra_usage -and $null -ne $data.extra_usage.is_enabled) {
            $result.ExtraUsage = [bool]$data.extra_usage.is_enabled
        }
        # Limite settimanale scoped sul modello principale (es. Fable):
        # arriva dall'array "limits" con kind=weekly_scoped e scope.model
        if ($data.limits) {
            $scoped = $data.limits | Where-Object { $_.kind -eq 'weekly_scoped' -and $_.scope -and $_.scope.model } | Select-Object -First 1
            if ($scoped) {
                $mName = if ($scoped.scope.model.display_name) { $scoped.scope.model.display_name } else { "Model" }
                $result.Model = [ordered]@{
                    Name        = $mName
                    Utilization = [math]::Round([double]$scoped.percent,1)
                    ResetsAt    = Parse-IsoDate $scoped.resets_at
                }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "401" -and -not $retried) {
            $nc = Invoke-TokenRefresh -force $true
            if ($nc) { return Get-UsageStats -retried $true }
            $script:LoginNeeded = $true  # refresh forzato fallito: serve login manuale, segnalalo subito
        }
        # Rate limit o qualsiasi errore: restituisce cache se disponibile
        if ($script:LastGoodStats) {
            $cached = [ordered]@{}
            foreach ($k in $script:LastGoodStats.Keys) { $cached[$k] = $script:LastGoodStats[$k] }
            $cached["Cached"] = $true; $cached["LastUpdated"] = Get-Date
            return $cached
        }
        $result.Error = if ($msg -match "429") { "Rate limit - dati in cache" } else {
            $s = $msg.Substring(0,[Math]::Min(77,$msg.Length)); if ($msg.Length -gt 77) { $s+'...' } else { $s }
        }
    }
    if (-not $result.Error) {
        $script:LastGoodStats = $result
        $script:LastFreshTime = Get-Date
        $script:LoginNeeded   = $false  # una chiamata reale e' andata a buon fine: il problema, se c'era, e' risolto
        Save-HistoryEntry $result
    }
    return $result
}

# ─── Login OAuth ──────────────────────────────────────────────────────────────
$script:DoLogin = {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/k claude auth login"
}
function Get-DataAgeHours {
    if (-not $script:LastFreshTime) { return [double]::PositiveInfinity }
    return ((Get-Date) - $script:LastFreshTime).TotalHours
}

# ─── Barra testo ──────────────────────────────────────────────────────────────
function Draw-Bar([double]$pct, [int]$width = 18) {
    $filled = [math]::Max(0,[math]::Min($width,[math]::Round($pct/100*$width)))
    return "[" + ("=" * $filled) + (" " * ($width-$filled)) + "]"
}

# ─── Stima andamento (pace) su una finestra temporale ─────────────────────────
function Get-Pace([double]$pct, $resetsAt, [double]$windowHours) {
    if (-not $resetsAt) { return $null }
    $start    = $resetsAt.AddHours(-$windowHours)
    $elapsedH = ([datetime]::Now - $start).TotalHours
    $expected = [math]::Round([math]::Max(0,[math]::Min(100, $elapsedH / $windowHours * 100)), 1)
    $delta    = [math]::Round($pct - $expected, 1)
    $label    = if ([math]::Abs($delta) -lt 3) { "(on track)" } `
                elseif ($delta -gt 0)          { "(+${delta}% over)" } `
                else                           { "($delta% under)" }
    return [pscustomobject]@{ Expected=$expected; Delta=$delta; Label=$label }
}

# ─── Menu contestuale ─────────────────────────────────────────────────────────
function Build-Menu($stats) {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    function Add-Label($text,[bool]$bold=$false) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $text; $item.Enabled = $false
        $item.Font = if ($bold) { New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold) } `
                     else       { New-Object System.Drawing.Font("Consolas",8.5) }
        $menu.Items.Add($item) | Out-Null
    }
    function Add-Sep() { $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

    Add-Label "  Claude Code  /usage" $true
    Add-Sep
    if ($stats.Error) {
        Add-Label "  $($stats.Error)"
    } else {
        if ($null -ne $stats.Session.Utilization) {
            $pct = $stats.Session.Utilization; $rst = $stats.Session.ResetsAt
            $mins = if ($rst) { [math]::Round(($rst-(Get-Date)).TotalMinutes) } else { 0 }
            $countdown = if (-not $rst) { "?" } elseif ($mins -le 0) { "now" } elseif ($mins -lt 60) { "in ${mins}min" } else { "in $([math]::Floor($mins/60))h $($mins%60)min" }
            $rstStr = if ($rst) { "$($rst.ToString('HH:mm'))  ($countdown)" } else { "?" }
            Add-Label "  Current session (5h)" $true
            Add-Label ("  {0}  {1,5:N1}%" -f (Draw-Bar $pct), $pct)
            Add-Label "  Resets: $rstStr"
            $pace = Get-Pace $pct $rst 5
            if ($pace) { Add-Label "  On pace: $($pace.Expected)%  actual: ${pct}%  $($pace.Label)" }
        }
        Add-Sep
        if ($null -ne $stats.Week.Utilization) {
            $pct = $stats.Week.Utilization; $rst = $stats.Week.ResetsAt
            $daysLeft = if ($rst) { [math]::Round(($rst-(Get-Date)).TotalDays,1) } else { 0 }
            $rstStr = if ($rst) { $rst.ToString("ddd MM/dd  HH:mm") + "  (in $daysLeft d)" } else { "?" }
            Add-Label "  Current week (7d)" $true
            Add-Label ("  {0}  {1,5:N1}%" -f (Draw-Bar $pct), $pct)
            Add-Label "  Resets: $rstStr"
            if ($rst) {
                $weekStart   = $rst.AddDays(-7)
                $elapsedH    = ([datetime]::Now - $weekStart).TotalHours
                $expectedPct = [math]::Round($elapsedH / 168 * 100, 1)
                $delta       = [math]::Round($pct - $expectedPct, 1)
                $paceStr     = if ([math]::Abs($delta) -lt 3) { "(on track)" } `
                               elseif ($delta -gt 0) { "(+${delta}% over)" } `
                               else { "($delta% under)" }
                Add-Label "  On pace: ${expectedPct}%  actual: ${pct}%  $paceStr"
            }
        }
        if ($stats.Model -and $null -ne $stats.Model.Utilization) {
            Add-Sep
            $pct = $stats.Model.Utilization; $rst = $stats.Model.ResetsAt
            $rstStr = if ($rst) { $rst.ToString("ddd MM/dd  HH:mm") } else { "?" }
            Add-Label "  $($stats.Model.Name) week (7d)" $true
            Add-Label ("  {0}  {1,5:N1}%" -f (Draw-Bar $pct), $pct)
            Add-Label "  Resets: $rstStr"
            $pace = Get-Pace $pct $rst 168
            if ($pace) { Add-Label "  On pace: $($pace.Expected)%  actual: ${pct}%  $($pace.Label)" }
        }
        Add-Sep
        $euText   = if ($stats.ExtraUsage) { "  Extra usage: ENABLED" } else { "  Extra usage: disabled" }
        Add-Label $euText
        $ptNow    = Get-PacificTime
        $dow      = [int]$ptNow.DayOfWeek
        $isPeakM  = ($dow -ge 1 -and $dow -le 5 -and $ptNow.Hour -ge 5 -and $ptNow.Hour -lt 11)
        if ($isPeakM) {
            # ends today at 11:00 PT
            $endPT    = $ptNow.Date.AddHours(11)
            $minLeft  = [math]::Round(($endPT - $ptNow).TotalMinutes)
            $timeStr  = if ($minLeft -ge 60) { "$([math]::Floor($minLeft/60))h $($minLeft % 60)min" } else { "${minLeft}min" }
            $peakText = "  Peak hours: ACTIVE  (ends in $timeStr)"
        } else {
            # find next Mon-Fri 05:00 PT
            $next = $ptNow.Date.AddHours(5)
            if ($ptNow.Hour -ge 11) { $next = $next.AddDays(1) }
            for ($i = 0; $i -lt 7; $i++) {
                $d = [int]$next.DayOfWeek
                if ($d -ge 1 -and $d -le 5) { break }
                $next = $next.AddDays(1)
            }
            $minLeft  = [math]::Round(($next - $ptNow).TotalMinutes)
            $timeStr  = if ($minLeft -ge 1440) { "$([math]::Floor($minLeft/1440))d $([math]::Floor(($minLeft%1440)/60))h" } `
                        elseif ($minLeft -ge 60) { "$([math]::Floor($minLeft/60))h $($minLeft % 60)min" } `
                        else { "${minLeft}min" }
            $peakText = "  Peak hours: off  (starts in $timeStr)"
        }
        Add-Label $peakText
    }
    Add-Sep
    $cacheNote = if ($stats.Cached) { " (cached)" } else { "" }
    Add-Label ("  Updated: {0:HH:mm:ss}{1}" -f $stats.LastUpdated, $cacheNote)
    Add-Sep
    $dataAge = Get-DataAgeHours
    if ($script:LoginNeeded -or $dataAge -gt $StaleAfterHours) {
        $ageLabel = if ([double]::IsInfinity($dataAge)) { "sconosciuta" } else { "$([math]::Round($dataAge,1))h" }
        $miStale = New-Object System.Windows.Forms.ToolStripMenuItem
        $miStale.Text = if ($script:LoginNeeded) { "  Token scaduto - Rinnova login" } else { "  Dati non aggiornati da $ageLabel - Rinnova login" }
        $menu.Items.Add($miStale) | Out-Null
        $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    } else {
        $miStale = $null
    }
    $miHistory = New-Object System.Windows.Forms.ToolStripMenuItem; $miHistory.Text = "  Usage history..."
    $menu.Items.Add($miHistory) | Out-Null
    $miLedger = New-Object System.Windows.Forms.ToolStripMenuItem; $miLedger.Text = "  Modello x Effort (ledger)"
    $menu.Items.Add($miLedger) | Out-Null
    $miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem; $miRefresh.Text = "  Refresh now"
    $menu.Items.Add($miRefresh) | Out-Null
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem; $miExit.Text = "  Exit"
    $menu.Items.Add($miExit) | Out-Null
    return [pscustomobject]@{ Menu=$menu; History=$miHistory; Ledger=$miLedger; Refresh=$miRefresh; Exit=$miExit; Stale=$miStale }
}

# ─── Icona tray ───────────────────────────────────────────────────────────────
function New-TrayIcon([double]$pctSess=0,[double]$deltaSess=0,[double]$pctWeek=0,[double]$deltaWeek=0,[bool]$isPeak=$false,$pctFable=$null,$deltaFable=0) {
    # Colore per scostamento dal ritmo atteso: verde sotto il previsto, giallo in linea/poco sopra,
    # rosso pesantemente sopra. Soglie assolute (95/100) restano come allarme "quasi esaurito".
    function BarColor([double]$p,[double]$delta) {
        if ($p -ge 100) { return [System.Drawing.Color]::FromArgb(55,55,55) }
        if ($p -ge 95)  { return [System.Drawing.Color]::FromArgb(100,0,0) }
        if ($delta -le -1) { return [System.Drawing.Color]::FromArgb(40,160,65) }
        if ($delta -le 7)  { return [System.Drawing.Color]::FromArgb(200,120,0) }
        return [System.Drawing.Color]::FromArgb(200,30,30)
    }
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(25,25,25))
    # Bordo 1px tutto intorno: giallo durante peak hour, blu fuori peak
    $borderColor = if ($isPeak) { [System.Drawing.Color]::FromArgb(255,215,0) } else { [System.Drawing.Color]::FromArgb(60,120,255) }
    $br = New-Object System.Drawing.SolidBrush($borderColor)
    $g.FillRectangle($br,0,0,16,1)
    $g.FillRectangle($br,0,15,16,1)
    $g.FillRectangle($br,0,0,1,16)
    $g.FillRectangle($br,15,0,1,16)
    $br.Dispose()
    $sepColor = [System.Drawing.Color]::FromArgb(10,10,10)
    # Barra sessione (righe 1-4, larghezza max 14px)
    $wS = [math]::Max(1,[math]::Round($pctSess/100*14))
    $br = New-Object System.Drawing.SolidBrush((BarColor $pctSess $deltaSess))
    $g.FillRectangle($br,1,1,$wS,4); $br.Dispose()
    $br = New-Object System.Drawing.SolidBrush($sepColor); $g.FillRectangle($br,1,5,14,1); $br.Dispose()
    # Barra settimana (righe 6-9, larghezza max 14px)
    $wW = [math]::Max(1,[math]::Round($pctWeek/100*14))
    $br = New-Object System.Drawing.SolidBrush((BarColor $pctWeek $deltaWeek))
    $g.FillRectangle($br,1,6,$wW,4); $br.Dispose()
    $br = New-Object System.Drawing.SolidBrush($sepColor); $g.FillRectangle($br,1,10,14,1); $br.Dispose()
    # Barra Fable (righe 11-14, larghezza max 14px) - vuota se il dato non e' disponibile
    if ($null -ne $pctFable) {
        $wF = [math]::Max(1,[math]::Round($pctFable/100*14))
        $br = New-Object System.Drawing.SolidBrush((BarColor $pctFable $deltaFable))
        $g.FillRectangle($br,1,11,$wF,4); $br.Dispose()
    }
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# ─── Init ─────────────────────────────────────────────────────────────────────
try {

$tray      = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$script:lastIconHandle = $tray.Icon.Handle
$tray.Visible = $true
$tray.Text    = "Claude Code Usage - loading..."

$script:hiddenForm = New-Object System.Windows.Forms.Form
$script:hiddenForm.ShowInTaskbar = $false
$script:hiddenForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:hiddenForm.Size = New-Object System.Drawing.Size(1,1)
$script:hiddenForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:hiddenForm.Location = New-Object System.Drawing.Point(-32000,-32000)
$script:hiddenForm.Show(); $script:hiddenForm.Hide()

$script:stats   = Get-UsageStats
$script:menuObj = Build-Menu $script:stats

function Update-Tray {
    $s = $script:stats
    if ($s.Error) {
        $text = "Claude Code - $($s.Error)"
        # NotifyIcon.Text ha un limite fisso di 63 caratteri (API Windows) - oltre lancia
        # un'eccezione. Sulla primissima chiamata (riga ~1273) nessun try/catch la ferma
        # e lo script termina: e' la causa dei crash all'avvio con rete/DNS non pronti.
        $tray.Text = $text.Substring(0,[Math]::Min(63,$text.Length))
        return
    }
    $sp  = if ($null -ne $s.Session.Utilization) { "$($s.Session.Utilization)%" } else { "?" }
    $wp  = if ($null -ne $s.Week.Utilization)    { "$($s.Week.Utilization)%" }    else { "?" }
    $fPctVal = if ($s.Model -and $null -ne $s.Model.Utilization) { [double]$s.Model.Utilization } else { $null }
    $fp  = if ($null -ne $fPctVal) { "$fPctVal%" } else { $null }
    $upd = if ($s.LastUpdated) { $s.LastUpdated.ToString("dd/MM HH:mm") } else { "mai" }
    $isPeak    = Get-IsPeakHour
    $peakTag   = if ($isPeak) { " | PEAK" } else { " | off-peak" }
    $sourceTag = if ($s.Source -eq "live") { " [live]" } else { "" }
    $fableTag  = if ($fp) { " | Fable:$fp" } else { "" }
    $text = "Claude  Sess:$sp | Week:$wp$fableTag$peakTag$sourceTag | $upd"
    $tray.Text = $text.Substring(0,[Math]::Min(63,$text.Length))

    $sPct   = if ($null -ne $s.Session.Utilization) { [double]$s.Session.Utilization } else { 0.0 }
    $wPct   = if ($null -ne $s.Week.Utilization)    { [double]$s.Week.Utilization }    else { 0.0 }
    $maxPct = [math]::Max($sPct, $wPct)
    # Scostamento dal ritmo atteso (pacing), usato per colorare icona e dashboard
    $sPace  = if ($s.Session.ResetsAt) { Get-Pace $sPct $s.Session.ResetsAt 5 } else { $null }
    $wPace  = if ($s.Week.ResetsAt)    { Get-Pace $wPct $s.Week.ResetsAt 168 } else { $null }
    $fPace  = if ($null -ne $fPctVal -and $s.Model.ResetsAt) { Get-Pace $fPctVal $s.Model.ResetsAt 168 } else { $null }
    $sDelta = if ($sPace) { $sPace.Delta } else { 0 }
    $wDelta = if ($wPace) { $wPace.Delta } else { 0 }
    $fDelta = if ($fPace) { $fPace.Delta } else { 0 }
    # Ridisegno sempre ad ogni refresh (ogni 5 min): il colore dipende dal delta di
    # pacing, che si sposta anche a % ferma (il "previsto" avanza col tempo) - un
    # confronto sulla sola % lasciava l'icona bloccata sul colore del refresh
    # precedente anche quando lo scostamento era nel frattempo rientrato.
    $newIcon = New-TrayIcon $sPct $sDelta $wPct $wDelta $isPeak $fPctVal $fDelta
    if ($script:lastIconHandle -ne [IntPtr]::Zero) {
        try { [Win32.NativeMethods]::DestroyIcon($script:lastIconHandle) | Out-Null } catch { }
    }
    $script:lastIconHandle = $newIcon.Handle
    $tray.Icon = $newIcon
    if ($maxPct -ge 90 -and -not $script:notified90) {
        $script:notified90 = $true
        $tray.ShowBalloonTip(8000,"Claude Code - Limit almost reached","Usage at $([math]::Round($maxPct,1))%",[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($maxPct -ge 85 -and -not $script:notified85) {
        $script:notified85 = $true
        $tray.ShowBalloonTip(6000,"Claude Code - High usage","Usage at $([math]::Round($maxPct,1))%",[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($maxPct -lt 75) {
        $script:notified85 = $false; $script:notified90 = $false
    }
    # Session event file — per trigger agenti esterni
    $curResetsAt = if ($s.Session.ResetsAt) { $s.Session.ResetsAt.ToString("o") } else { "" }
    if ($curResetsAt -and $script:lastSessResetsAt -and $curResetsAt -ne $script:lastSessResetsAt) {
        # ResetsAt cambiato = nuova sessione 5h iniziata
        try {
            $evJson = "{`"event`":`"session_reset`",`"timestamp`":`"$([datetime]::Now.ToString('o'))`",`"utilization`":$sPct,`"resetsAt`":`"$curResetsAt`"}"
            [System.IO.File]::WriteAllText($SessionEventFile, $evJson, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    if ($sPct -ge 95 -and $curResetsAt) {
        try {
            $evJson = "{`"event`":`"session_full`",`"timestamp`":`"$([datetime]::Now.ToString('o'))`",`"utilization`":$sPct,`"resetsAt`":`"$curResetsAt`"}"
            [System.IO.File]::WriteAllText($SessionEventFile, $evJson, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    if ($curResetsAt) { $script:lastSessResetsAt = $curResetsAt }

    # === USAGE SNAPSHOT JSON per consumatori esterni (Maggiordomo bridge) ===
    # Esporta TUTTI i dati che il menu tasto-destro mostra, in formato
    # JSON consumabile. Scritto ad ogni Update-Tray (= ogni 5 min + on-demand).
    try {
        $snap = [ordered]@{
            ts            = [datetime]::Now.ToString("o")
            source        = if ($s.Source) { $s.Source } else { if ($s.Cached) { "cached" } else { "unknown" } }
            cached        = [bool]$s.Cached
            error         = if ($s.Error) { $s.Error } else { $null }
            last_updated  = if ($s.LastUpdated) { $s.LastUpdated.ToString("o") } else { $null }
            session       = $null
            week          = $null
            model         = $null
            extra_usage   = [bool]$s.ExtraUsage
            peak          = $null
        }
        if ($null -ne $s.Session.Utilization) {
            $rst = $s.Session.ResetsAt
            $rim = if ($rst) { [math]::Round(($rst - (Get-Date)).TotalMinutes) } else { $null }
            $snap.session = [ordered]@{
                pct           = [double]$s.Session.Utilization
                resets_at     = if ($rst) { $rst.ToString("o") } else { $null }
                resets_in_min = $rim
                expected_pct  = $null
                delta_pct     = $null
                pace_label    = $null
            }
            $pace = Get-Pace ([double]$s.Session.Utilization) $rst 5
            if ($pace) {
                $snap.session.expected_pct = $pace.Expected
                $snap.session.delta_pct    = $pace.Delta
                $snap.session.pace_label   = if ([math]::Abs($pace.Delta) -lt 3) { "on_track" } elseif ($pace.Delta -gt 0) { "over_pace" } else { "under_pace" }
            }
        }
        if ($null -ne $s.Week.Utilization) {
            $rst = $s.Week.ResetsAt
            $wd = [ordered]@{
                pct             = [double]$s.Week.Utilization
                resets_at       = if ($rst) { $rst.ToString("o") } else { $null }
                resets_in_days  = if ($rst) { [math]::Round(($rst - (Get-Date)).TotalDays, 2) } else { $null }
                expected_pct    = $null
                delta_pct       = $null
                pace_label      = $null
            }
            if ($rst) {
                $weekStart   = $rst.AddDays(-7)
                $elapsedH    = ([datetime]::Now - $weekStart).TotalHours
                $expectedPct = [math]::Round($elapsedH / 168 * 100, 1)
                $delta       = [math]::Round([double]$s.Week.Utilization - $expectedPct, 1)
                $pace = if ([math]::Abs($delta) -lt 3) { "on_track" } `
                        elseif ($delta -gt 0)         { "over_pace" } `
                        else                          { "under_pace" }
                $wd.expected_pct = $expectedPct
                $wd.delta_pct    = $delta
                $wd.pace_label   = $pace
            }
            $snap.week = $wd
        }
        if ($s.Model -and $null -ne $s.Model.Utilization) {
            $rst = $s.Model.ResetsAt
            $snap.model = [ordered]@{
                name         = $s.Model.Name
                pct          = [double]$s.Model.Utilization
                resets_at    = if ($rst) { $rst.ToString("o") } else { $null }
                expected_pct = $null
                delta_pct    = $null
                pace_label   = $null
            }
            $pace = Get-Pace ([double]$s.Model.Utilization) $rst 168
            if ($pace) {
                $snap.model.expected_pct = $pace.Expected
                $snap.model.delta_pct    = $pace.Delta
                $snap.model.pace_label   = if ([math]::Abs($pace.Delta) -lt 3) { "on_track" } elseif ($pace.Delta -gt 0) { "over_pace" } else { "under_pace" }
            }
        }
        # Peak hours (replica della logica di Build-Menu)
        $ptNow  = Get-PacificTime
        $dowPt  = [int]$ptNow.DayOfWeek
        $isPeak = ($dowPt -ge 1 -and $dowPt -le 5 -and $ptNow.Hour -ge 5 -and $ptNow.Hour -lt 11)
        $pk = [ordered]@{
            active                 = [bool]$isPeak
            label                  = $null
            minutes_to_next_change = $null
        }
        if ($isPeak) {
            $endPT   = $ptNow.Date.AddHours(11)
            $minLeft = [math]::Round(($endPT - $ptNow).TotalMinutes)
            $pk.label = "active_ends_in"
            $pk.minutes_to_next_change = $minLeft
        } else {
            $next = $ptNow.Date.AddHours(5)
            if ($ptNow.Hour -ge 11) { $next = $next.AddDays(1) }
            for ($i = 0; $i -lt 7; $i++) {
                $d = [int]$next.DayOfWeek
                if ($d -ge 1 -and $d -le 5) { break }
                $next = $next.AddDays(1)
            }
            $minLeft = [math]::Round(($next - $ptNow).TotalMinutes)
            $pk.label = "off_starts_in"
            $pk.minutes_to_next_change = $minLeft
        }
        $snap.peak = $pk

        $snap.last_fresh_fetch = if ($script:LastFreshTime) { $script:LastFreshTime.ToString("o") } else { $null }
        $snapPath = Join-Path $PSScriptRoot "usage-snapshot.json"
        [System.IO.File]::WriteAllText($snapPath, ($snap | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
        try {
            $nowUtc = [datetime]::UtcNow
            $tsVal = $snap.ts
            if ((-not $script:LastHistoryAppendTime -or ($nowUtc - $script:LastHistoryAppendTime).TotalSeconds -ge 110) -and $tsVal -ne $script:LastHistoryTs) {
                $histPath = Join-Path $PSScriptRoot "usage-history.jsonl"
                $histLine = $snap | ConvertTo-Json -Compress -Depth 5
                [System.IO.File]::AppendAllText($histPath, $histLine + "`n", (New-Object System.Text.UTF8Encoding $false))
                $script:LastHistoryAppendTime = $nowUtc
                $script:LastHistoryTs = $tsVal
            }
        } catch {}
    } catch {
        "$([datetime]::Now) snapshot ERRORE: $_" | Out-File $LogFile -Append -Encoding UTF8
    }
}
# Rete rinforzo: la primissima chiamata (all'avvio, es. subito dopo login Windows
# con DNS non ancora pronto) non va protetta dal try/catch di DoRefresh - senza
# questo, un'eccezione qui terminava l'intero script prima di mostrare l'icona.
Seed-LastGoodStats
try { Update-Tray } catch {
    "$([datetime]::Now) Update-Tray iniziale ERRORE: $_`n$($_.ScriptStackTrace)" | Out-File $LogFile -Append -Encoding UTF8
}

$script:DoShowHistory = { Show-HistoryChart }

$script:DoOpenLedger = {
    $ledgerPath = "C:\Claude Projects\Ottimizza Token\usage-ledger\dashboard.html"
    if (Test-Path $ledgerPath) {
        Start-Process $ledgerPath
    } else {
        $tray.ShowBalloonTip(5000,"Claude Code",'dashboard non ancora generata: lancia run_all.py',[System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# DoRefresh: aggiorna dati API e icona (chiamato da timer e "Aggiorna ora")
$script:DoRefresh = {
    try {
        $script:stats = Get-UsageStats
        Update-Tray
    } catch {
        "$([datetime]::Now) DoRefresh ERRORE: $_" | Out-File $LogFile -Append -Encoding UTF8
    }
}

$script:DoExit = {
    $script:refreshTimer.Stop(); $script:refreshTimer.Dispose()
    if ($script:hiddenForm) { $script:hiddenForm.Dispose() }
    $tray.Visible = $false; $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$script:menuObj.History.add_Click($script:DoShowHistory)
$script:menuObj.Ledger.add_Click($script:DoOpenLedger)
$script:menuObj.Refresh.add_Click($script:DoRefresh)
if ($script:menuObj.Stale) { $script:menuObj.Stale.add_Click($script:DoLogin) }
$script:menuObj.Exit.add_Click($script:DoExit)

$tray.add_MouseClick({
    param($s,$e)
    try {
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        [Win32.NativeMethods]::SetForegroundWindow($script:hiddenForm.Handle) | Out-Null
        # Ricostruisce menu da cache (nessuna chiamata API)
        $old = $script:menuObj
        $script:menuObj = Build-Menu $script:stats
        $script:menuObj.History.add_Click($script:DoShowHistory)
        $script:menuObj.Ledger.add_Click($script:DoOpenLedger)
        $script:menuObj.Refresh.add_Click($script:DoRefresh)
        if ($script:menuObj.Stale) { $script:menuObj.Stale.add_Click($script:DoLogin) }
        $script:menuObj.Exit.add_Click($script:DoExit)
        if ($old) { $old.Menu.Dispose() }
        # Monitor impilati in verticale: il menu aperto verso il basso dal
        # cursore sconfina sul monitor sotto. Apertura forzata verso l'alto,
        # ancorata dentro l'area di lavoro del monitor primario.
        $pos = [System.Windows.Forms.Cursor]::Position
        $wa  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = [math]::Max($wa.Left, [math]::Min($pos.X, $wa.Right  - 1))
        $y = [math]::Max($wa.Top,  [math]::Min($pos.Y, $wa.Bottom - 1))
        $script:menuObj.Menu.Show((New-Object System.Drawing.Point($x,$y)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveLeft)
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $st = $script:stats
        $msg = if ($st.Error) { $st.Error } else {
            $sp = if ($null -ne $st.Session.Utilization) { "$($st.Session.Utilization)%" } else { "?" }
            $wp = if ($null -ne $st.Week.Utilization)    { "$($st.Week.Utilization)%" }    else { "?" }
            $sr = if ($st.Session.ResetsAt) { $st.Session.ResetsAt.ToString("HH:mm") } else { "?" }
            $wr = if ($st.Week.ResetsAt)    { $st.Week.ResetsAt.ToString("ddd dd/MM HH:mm") } else { "?" }
            "Session: $sp   [resets $sr]`nWeekly: $wp   [resets $wr]"
        }
        $s.ShowBalloonTip(5000,"Claude Code /usage",$msg,[System.Windows.Forms.ToolTipIcon]::Info)
    }
    } catch {
        "$([datetime]::Now) MouseClick ERRORE: $_`n$($_.ScriptStackTrace)" | Out-File $LogFile -Append -Encoding UTF8
    }
})

# Auto-refresh ogni 5 minuti
$script:refreshTimer = New-Object System.Windows.Forms.Timer
$script:refreshTimer.Interval = 300000
$script:refreshTimer.add_Tick({ & $script:DoRefresh })
$script:refreshTimer.Start()

# Reti di sicurezza: logga eccezioni UI e di dominio invece di morire in silenzio
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender,$ev)
    "$([datetime]::Now) ThreadException: $($ev.Exception)" | Out-File $LogFile -Append -Encoding UTF8
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender,$ev)
    "$([datetime]::Now) UnhandledException: $($ev.ExceptionObject)" | Out-File $LogFile -Append -Encoding UTF8
})

[System.Windows.Forms.Application]::Run()

} catch {
    "$([datetime]::Now) ERRORE: $_`n$($_.ScriptStackTrace)" |
        Out-File $LogFile -Append -Encoding UTF8
}
