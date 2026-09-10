@echo off
copy /Y "%~dp0Kaalu.vbs" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Kaalu.vbs" >nul
echo Done! Kaalu will greet you at every login.
echo Press any key to close.
pause >nul
