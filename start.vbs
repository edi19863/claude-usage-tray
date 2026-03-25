' Lancia claude-tray.ps1 senza finestra console
Dim WshShell
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File """ & _
    CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\claude-tray.ps1""", 0, False
Set WshShell = Nothing
