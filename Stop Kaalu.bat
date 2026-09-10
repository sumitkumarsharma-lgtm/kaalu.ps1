@echo off
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*kaalu.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo Kaalu stopped. (Tip: the friendlier way is his menu -^> Bye Kaalu)
echo Press any key to close.
pause >nul
