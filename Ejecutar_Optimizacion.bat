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

REM Si llegamos aquí, el script de PowerShell terminó
if %errorlevel% neq 0 (
    echo.
    echo ========================================
    echo           ADVERTENCIA
    echo ========================================
    echo.
    echo El script no se ejecuto como Administrador
    echo Muchas optimizaciones requieren permisos de admin
    echo.
    echo Solucion: Ejecutar este .bat como Administrador
    echo.
    echo - Boton derecho en el archivo
    echo - Ejecutar como administrador
    echo.
)
