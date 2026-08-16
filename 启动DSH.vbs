' DeepSeek Harness 启动器 · 无控制台窗口启动 (Run 0 = 完全隐藏)
' 双击本文件或快捷方式指向: wscript.exe "本文件路径"
Set ws = CreateObject("WScript.Shell")
launcherDir = "C:\Users\tang\Documents\deepseek"
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcherDir & "\dsh-launcher.ps1"" -HideConsole"
ws.Run cmd, 0, False
