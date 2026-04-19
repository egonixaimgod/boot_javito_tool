@echo off
:: BootFixer Indító
:: Automatikusan rendszergazdaként futtatja a PowerShell scriptet
title BootFixer - Boot Javito Eszkoz

:: Admin jogosultság kérése
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Rendszergazdai jogosultsag kerese...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: PowerShell script futtatása
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BootFixer.ps1"
pause
