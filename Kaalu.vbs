' Kaalu silent launcher - double-click to wake up Kaalu
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""C:\Users\ssharma66\Kaalu\kaalu.ps1""", 0, False
