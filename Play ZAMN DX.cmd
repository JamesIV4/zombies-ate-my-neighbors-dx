@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
if errorlevel 1 (
	echo.
	echo The launcher could not start Zombies Ate My Neighbors DX.
	pause
)
