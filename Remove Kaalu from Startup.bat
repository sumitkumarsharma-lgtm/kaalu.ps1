@echo off
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Kaalu.vbs" 2>nul
echo Kaalu removed from startup (he can still be launched manually).
echo Press any key to close.
pause >nul
