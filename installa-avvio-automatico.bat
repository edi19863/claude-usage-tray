@echo off
:: Crea scorciatoia nella cartella Startup di Windows
:: Eseguire come utente normale (non richiede privilegi di amministratore)

set "SCRIPT_DIR=%~dp0"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=%STARTUP_DIR%\ClaudeUsageTray.lnk"
set "VBS_LAUNCHER=%SCRIPT_DIR%start.vbs"

:: Crea la scorciatoia via PowerShell
powershell -Command "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%SHORTCUT%'); $sc.TargetPath = 'wscript.exe'; $sc.Arguments = '\"%VBS_LAUNCHER%\"'; $sc.WorkingDirectory = '%SCRIPT_DIR%'; $sc.Description = 'Claude Code Usage Tray'; $sc.Save()"

if exist "%SHORTCUT%" (
    echo.
    echo  [OK] Avvio automatico configurato!
    echo       Claude Usage Tray si avviera' ad ogni login.
    echo.
    echo  Vuoi avviarlo adesso?
    choice /c SN /m "S=Si  N=No"
    if errorlevel 2 goto fine
    wscript.exe "%VBS_LAUNCHER%"
) else (
    echo  [ERRORE] Non riuscito a creare la scorciatoia.
)

:fine
echo.
pause
