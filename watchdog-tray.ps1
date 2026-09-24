# Watchdog: se claude-tray.ps1 non e' in esecuzione, lo rilancia.
# Eseguito dal task pianificato "ClaudeUsageTrayWatchdog" (al login + ogni 5 minuti).

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbsLauncher = Join-Path $scriptDir "start.vbs"

$markerPath = Join-Path $scriptDir "claude-tray.ps1"
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*-File*`"$markerPath`"*" }

if (-not $running) {
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbsLauncher`"" -WindowStyle Hidden
    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Tray non attivo, riavviato"
} else {
    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Tray attivo (PID $($running[0].ProcessId))"
}

Add-Content -Path (Join-Path $scriptDir "watchdog.log") -Value $logLine -Encoding UTF8

# Mantieni il log sotto le 200 righe
$logPath = Join-Path $scriptDir "watchdog.log"
if (Test-Path $logPath) {
    $lines = Get-Content $logPath
    if ($lines.Count -gt 200) {
        $lines[-200..-1] | Set-Content $logPath -Encoding UTF8
    }
}
