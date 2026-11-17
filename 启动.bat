@echo off
title Course Video Autoplay Helper
cd /d "%~dp0"
rem Auto-heal encoding: ensure player.ps1 has UTF-8 BOM (Windows PowerShell 5.1 requires it)
powershell.exe -NoProfile -Command "$f=Join-Path (Get-Location) 'player.ps1';$b=[IO.File]::ReadAllBytes($f);if($b.Length -gt 3 -and $b[0] -ne 239){[IO.File]::WriteAllBytes($f,[byte[]](239,187,191)+$b)}"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0player.ps1" %*
echo.
echo Program exited.
pause
