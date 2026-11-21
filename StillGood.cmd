@echo off
rem StillGood - double-click to open the StillGood window. Windows asks for administrator rights once.
rem Everything it does is in StillGood.ps1 and the modules folder, in plain text you can read.
setlocal
title StillGood
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
for %%F in (StillGood.ps1 modules\_load.ps1 modules\Gui.psm1 modules\GuiCore.psm1 catalog\apps.json worker\Upgrade-Worker.ps1) do (
    if not exist "%~dp0%%F" (
        echo StillGood cannot find %%F.
        echo Extract the whole StillGood folder from the zip first, then run StillGood.cmd from inside it.
        pause
        exit /b 1
    )
)
start "" "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0StillGood.ps1" -Mode Window
exit /b 0
