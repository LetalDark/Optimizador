@echo off
title Optimizador
color 0A

REM Obtener la ruta donde esta este .bat
set "BAT_DIR=%~dp0"
set "BAT_DIR=%BAT_DIR:~0,-1%"

echo [OPTIMIZADOR] Ruta de trabajo: %BAT_DIR%
echo.

echo [OPTIMIZADOR] Actualizando script...
powershell -Command "try { $progressPreference = 'silentlyContinue'; iwr -Uri 'https://github.com/LetalDark/Optimizador/raw/refs/heads/main/optimizacion.ps1' -OutFile '%BAT_DIR%\optimizacion.ps1' -UseBasicParsing; write-host '[OK] Actualizado' -fore green } catch { write-host '[INFO] Usando version local' -fore yellow }"

REM Ejecutar en misma ventana desde la ruta correcta
cd /d "%BAT_DIR%"
powershell -ExecutionPolicy Bypass -File "optimizacion.ps1"
