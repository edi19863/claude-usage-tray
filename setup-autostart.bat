@echo off
:: Creates a shortcut in Windows Startup folder so the tray starts at login
:: Does NOT require administrator privileges

set "SCRIPT_DIR=%~dp0"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=%STARTUP_DIR%\ClaudeUsageTray.lnk"
set "VBS_LAUNCHER=%SCRIPT_DIR%start.vbs"

powershell -Command "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%SHORTCUT%'); $sc.TargetPath = 'wscript.exe'; $sc.Arguments = '\"%VBS_LAUNCHER%\"'; $sc.WorkingDirectory = '%SCRIPT_DIR%'; $sc.Description = 'Claude Code Usage Tray'; $sc.Save()"

if exist "%SHORTCUT%" (
    echo.
    echo  [OK] Auto-start configured!
    echo       Claude Usage Tray will start automatically at every login.
    echo.
    echo  Launch now?
    choice /c YN /m "Y=Yes  N=No"
    if errorlevel 2 goto done
    wscript.exe "%VBS_LAUNCHER%"
) else (
    echo  [ERROR] Could not create the shortcut.
)

:done
echo.
pause
