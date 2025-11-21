# optimizacion.ps1
# Optimizador

# Ejecutar como ADMINISTRADOR
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Ejecutar como ADMINISTRADOR" -ForegroundColor Red
    Read-Host "Presiona Enter para salir"
    exit
}

$ErrorActionPreference = "Stop"

# Cargar APIs solo una vez y SIN CONFLICTOS
if (-not ([System.Management.Automation.PSTypeName]'Win32Zoom').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Zoom {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@ -ErrorAction SilentlyContinue
}

# === ZOOM 85% + MAXIMIZAR ===
function Set-ConsoleZoomAndMaximize {
    try {
        $hwnd = [Win32Zoom]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500; $hwnd = [Win32Zoom]::GetForegroundWindow() }

        # MAXIMIZAR
        [Win32Zoom]::ShowWindow($hwnd, 3) | Out-Null
        Start-Sleep -Milliseconds 900

        # Forzar foco (crucial)
        [Win32Zoom]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 300

        # ZOOM 85% → 1 paso abajo
        $wParam = [IntPtr](0x0008 -bor (-120 -shl 16))
        [Win32Zoom]::PostMessage($hwnd, 0x020A, $wParam, [IntPtr]::Zero) | Out-Null

        Write-Host "Ventana maximizada + zoom al 85%" -ForegroundColor Cyan
    } catch { }
}

# === ZOOM 100% ===
function Restore-ConsoleZoom {
    try {
        $hwnd = [Win32Zoom]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }

        [Win32Zoom]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 200

        $wParam = [IntPtr](0x0008 -bor (120 -shl 16))
        [Win32Zoom]::PostMessage($hwnd, 0x020A, $wParam, [IntPtr]::Zero) | Out-Null
    } catch { }
}

# === AUTO-ACTUALIZAR .BAT ===
function Update-BatchFile {
    $batName = "Ejecutar_Optimizacion.bat"
    $batPath = Join-Path $PSScriptRoot $batName
    $url = "https://github.com/LetalDark/Optimizador/raw/refs/heads/main/$batName"

    if (-not (Test-Path $batPath)) { 
        Write-Verbose "Batch file not found" -Verbose
        return 
    }

    try {
        Log-Progress "Actualizando $batName..." Yellow
        $tempBat = "$batPath.tmp"
        Invoke-WebRequest -Uri $url -OutFile $tempBat -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop

        # Comparar contenido (solo si cambió)
        $current = Get-Content $batPath -Raw -ErrorAction SilentlyContinue
        $new = Get-Content $tempBat -Raw
        if ($current -ne $new) {
            Move-Item $tempBat $batPath -Force
            Log-Progress "$batName actualizado" Green
            # No retornar valor
        } else {
            Remove-Item $tempBat -Force
            Log-Progress "$batName ya esta actualizado" Gray
            # No retornar valor
        }
    } catch {
        Log-Progress "ERROR al actualizar .bat: $($_.Exception.Message)" Red
        if (Test-Path "$batPath.tmp") { Remove-Item "$batPath.tmp" -Force }
        # No retornar valor
    }
}

# === INICIALIZAR ENTORNO (RUTAS + BACKUP) ===
function RegistersBackup {
    # --- Rutas de registro ---
    $script:reg1Path = "HKLM:\SYSTEM\CurrentControlSet\Services\EhStorClass\Parameters"
    $script:reg1Name = "StorageSupportedFeatures"
    $script:reg2Path = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
    $script:reg2Name = "OverlayTestMode"
    $script:reg3Base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $script:reg3Name = "ShaderCache"

    # --- Backup ---
    $backupRoot = "C:\Temp"
    $backupDir = "$backupRoot\Backup_Registros"
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupPath = "$backupDir\Backup_$timestamp"

    try {
        if (-not (Test-Path $backupRoot)) { New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
    } catch {
        Write-Host "ERROR: No se pudo crear backup en C:\Temp" -ForegroundColor Red
        Read-Host "Presiona Enter para salir"
        exit
    }

    $backupFiles = @()
    $keys = @(
        @{key="HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EhStorClass\Parameters"; file="1_EhStorClass.reg"},
        @{key="HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Dwm"; file="2_Dwm.reg"},
        @{key="HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"; file="3_DisplayClass.reg"}
    )

    foreach ($item in $keys) {
        $filePath = "$backupPath\$($item.file)"
        $cmd = "reg export `"$($item.key)`" `"$filePath`" /y"
        try {
            Invoke-Expression $cmd | Out-Null
            if (Test-Path $filePath) { $backupFiles += $item.file }
        } catch { }
    }

    $script:backupPath = $backupPath
    $script:backupInfo = if ($backupFiles.Count -eq 3) { "Backup OK: $backupPath" } else { "Backup PARCIAL: $backupPath" }
}

# === COMPROBAR SI HUBO REINICIO DESDE ÚLTIMA EJECUCIÓN ===
function Test-RebootSinceLastRun {
    $lastBackup = Get-ChildItem "C:\Temp\Backup_Registros" -ErrorAction SilentlyContinue | 
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $lastBackup) { return $false }

    # Última vez que se modificó un backup
    $lastBackupTime = $lastBackup.LastWriteTime

    # Hora de arranque del sistema
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

    return $bootTime -gt $lastBackupTime
}

# === GENERAR Y LEER TXT DE CPU-Z (XMP + RAM + PLACA BASE) ===
function Update-CPUZInfo {
    try {
        $scriptPath = $PSScriptRoot
        if (-not $scriptPath) { $scriptPath = (Get-Location).Path }
        $zipUrl = "https://download.cpuid.com/cpu-z/cpu-z_2.17-en.zip"
        $zipPath = "$scriptPath\cpuz.zip"
        $exePath = "$scriptPath\cpuz_x64.exe"
        $txtPath = "$scriptPath\meminfo.txt"

		# === OPTIMIZACIÓN: REUTILIZAR SI NO HUBO REINICIO ===
        $skipGeneration = $false
        if (-not (Test-RebootSinceLastRun) -and (Test-Path $txtPath)) {
            $fileAge = (Get-Date) - (Get-Item $txtPath).LastWriteTime
            if ($fileAge.TotalHours -lt 48) {
                Log-Progress "# Reutilizando meminfo.txt existente" Green -Subsection
                $skipGeneration = $true
            }
        }

		if (-not $skipGeneration) {
			# === DESCARGAR Y EXTRAER CPU-Z ===
			if (-not (Test-Path $exePath)) {
				Log-Progress "Descargando CPU-Z..." Yellow
				try {
					Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30
					Log-Progress "Extrayendo CPU-Z..." Yellow
					$shell = New-Object -ComObject Shell.Application
					$zip = $shell.NameSpace($zipPath)
					foreach ($item in $zip.Items()) { $shell.NameSpace($scriptPath).CopyHere($item, 0x14) }
					Remove-Item $zipPath -Force
					Start-Sleep -Milliseconds 300
					if (-not (Test-Path $exePath)) { throw "No se encontro cpuz_x64.exe" }
					Log-Progress "CPU-Z descargado y extraido correctamente." Green
				} catch {
					$script:cpuzInfo = "Error al descargar CPU-Z"
					$script:motherboard = "No disponible"
					$script:xmpAdvice = $null
					Log-Progress "ERROR: $($_.Exception.Message)" Red -Error
					return
				}
			}

			# === INICIO CPU-Z ===
			Log-Progress "# INICIANDO CPU-Z" Cyan -Subsection
			Log-Progress "# ----------------------------------------------------" Gray -Subsection

			# === EJECUTAR CPU-Z ===
			Log-Progress "# Ejecutando CPU-Z..." Cyan -Subsection
			if (Test-Path $txtPath) { Remove-Item $txtPath -Force }

			# Ejecutar CPU-Z
			$process = Start-Process -FilePath $exePath -ArgumentList "-txt=meminfo.txt" -WorkingDirectory $scriptPath -PassThru -WindowStyle Hidden
			if (-not $process) {
				$script:cpuzInfo = "Error: No se pudo iniciar CPU-Z"
				$script:motherboard = "No disponible"
				Log-Progress "$script:cpuzInfo" Red -Error
				return
			}

			Log-Progress "# GENERANDO MEMINFO.TXT" Yellow -Subsection

			# === ESPERA PACIENTE SIN FORZAR CIERRE ===
			$maxWait = 60  # Aumentado a 60 segundos para PCs viejos
			$txtReady = $false
			$fileDetected = $false

			for ($i = 0; $i -lt $maxWait; $i++) {
				Start-Sleep -Seconds 1
				
				# === GESTIÓN DE NOMBRES DE ARCHIVO ===
				$actualTxtPath = $txtPath
				
				# Verificar diferentes nombres que CPU-Z puede generar
				$possibleNames = @(
					$txtPath,                    # meminfo.txt
					"$txtPath.txt",              # meminfo.txt.txt  
					"meminfo",                   # meminfo (sin extensión)
					"meminfo.txt.tmp"            # Temporal
				)
				
				foreach ($possibleFile in $possibleNames) {
					if (Test-Path $possibleFile) {
						if ($possibleFile -ne $txtPath) {
							#Log-Progress "# RENOMBRANDO: $possibleFile -> meminfo.txt" Yellow -Subsection
							try {
								Rename-Item $possibleFile "meminfo.txt" -Force -ErrorAction Stop
								$actualTxtPath = $txtPath
								Log-Progress "# Archivo renombrado correctamente" Green -Subsection
								break
							} catch {
								Log-Progress "# Archivo en uso, esperando..." DarkGray -Subsection
							}
						} else {
							$actualTxtPath = $txtPath
							break
						}
					}
				}
				
				# Verificar si el archivo existe
				if (Test-Path $actualTxtPath) {
					$fileDetected = $true
					
					try {
						$fileInfo = Get-Item $actualTxtPath -ErrorAction Stop
						$fileSize = $fileInfo.Length
						
						# El archivo debe tener al menos 1KB para ser útil
						if ($fileSize -gt 1024) {
							# Verificar que el archivo no esté bloqueado
							$fileStream = $null
							try {
								$fileStream = [System.IO.File]::Open($actualTxtPath, 'Open', 'Read', 'None')
								$fileStream.Close()
								
								# Intentar leer el contenido
								$testContent = Get-Content $actualTxtPath -Raw -ErrorAction Stop
								if ($testContent -and $testContent.Length -gt 1000) {
									# Verificar que tenga contenido crítico
									if ($testContent -match "DMI Baseboard" -and $testContent -match "Memory") {
										$txtReady = $true
										Log-Progress "# TXT VALIDO DETECTADO ($i segundos, $fileSize bytes)" Green -Subsection
										
										# CPU-Z terminó exitosamente, podemos cerrarlo amablemente
										if (-not $process.HasExited) {
											Log-Progress "# Cerrando CPU-Z..." DarkGray -Subsection
											$process.CloseMainWindow() | Out-Null
											Start-Sleep -Milliseconds 500
											if (-not $process.HasExited) {
												$process.Kill()
											}
										}
										break
									} else {
										if ($i % 5 -eq 0) {
											Log-Progress "# Generando informe... ($i segundos)" DarkGray -Subsection
										}
									}
								}
							} catch {
								# Archivo bloqueado - CPU-Z todavía escribiendo
								if ($i % 5 -eq 0) {
									Log-Progress "# CPU-Z escribiendo archivo... ($i segundos)" DarkGray -Subsection
								}
							} finally {
								if ($fileStream) { $fileStream.Close() }
							}
						} else {
							# Archivo existe pero es muy pequeño
							if ($i % 5 -eq 0) {
								Log-Progress "# Iniciando generacion... ($fileSize bytes)" DarkGray -Subsection
							}
						}
					} catch {
						# Error accediendo al archivo
						if ($i % 5 -eq 0) {
							Log-Progress "# Preparando archivo... ($i segundos)" DarkGray -Subsection
						}
					}
				} else {
					# Archivo aún no existe
					if ($i % 5 -eq 0) {
						Log-Progress "# Iniciando CPU-Z... ($i/$maxWait segundos)" DarkGray -Subsection
					}
				}
				
				# Feedback progresivo para PCs viejos
				if ($i -eq 15) {
					Log-Progress "# CPU-Z esta trabajando... (paciencia en PCs viejos)" Yellow -Subsection
				}
				elseif ($i -eq 30) {
					Log-Progress "# CPU-Z esta recopilando mucha informacion..." Yellow -Subsection
				}
			}

			# === VERIFICAR RESULTADO ===
			if (-not $txtReady) {
				# Solo forzar cierre si realmente es necesario (timeout completo)
				if (-not $process.HasExited) {
					Log-Progress "# CPU-Z tardo demasiado, cerrando..." Yellow -Subsection
					$process.CloseMainWindow() | Out-Null
					Start-Sleep -Seconds 2
					if (-not $process.HasExited) {
						$process.Kill()
					}
				}
				
				# Intentar usar el TXT aunque esté incompleto
				if (Test-Path $txtPath -and (Get-Item $txtPath).Length -gt 500) {
					try {
						$testContent = Get-Content $txtPath -Raw -ErrorAction Stop
						if ($testContent -and $testContent.Length -gt 500) {
							Log-Progress "# Usando TXT parcialmente generado" Yellow -Subsection
							$txtReady = $true
						}
					} catch {
						# No se pudo usar el TXT
					}
				}
				
				if (-not $txtReady) {
					$script:cpuzInfo = "CPU-Z no genero un TXT valido (timeout de $maxWait segundos)"
					$script:motherboard = "No disponible"
					Log-Progress "$script:cpuzInfo" Red -Error
					return
				}
			}
		}

        Log-Progress "# PROCESANDO INFORMACION DE CPU/MEMORIA..." Yellow -Subsection

        # === LEER TODO Y LIMPIAR ACENTOS ===
        $rawText = Get-Content $txtPath -Raw -Encoding Default
        $lines = $rawText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        $lines = $lines -replace '[^\x00-\x7F]', 'a' # QUITAR ACENTOS

        # === DETECCION DE PLACA BASE ===
        Log-Progress "# BUSCANDO DMI BASEBOARD" Cyan -Subsection
        $found = $false
        $motherboardModel = "Desconocido"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq "DMI Baseboard") {
                $modelLineIndex = $i + 2
                if ($modelLineIndex -lt $lines.Count) {
                    $modelLine = $lines[$modelLineIndex].Trim()
                    if ($modelLine -match "^model\s+(.+)") {
                        $motherboardModel = $matches[1].Trim()
                        Log-Progress "# MODELO ENCONTRADO: $motherboardModel" Yellow -Subsection
                        $found = $true
                    }
                }
                break
            }
        }
        if (-not $found) {
            Log-Progress "# ADVERTENCIA: No se encontro DMI Baseboard" Yellow -Subsection
        }
        $script:motherboard = $motherboardModel

        # === XMP + RAM ===
        $xmpProfiles = @()
        $currentSpeed = 0
        $timingsFound = $false
        
        foreach ($line in $lines) {
            # Detectar perfiles XMP
            if ($line -match "XMP profile\s+XMP-(\d+)") { 
                $xmpProfiles += [int]$matches[1] 
            }
            # Detectar velocidad de memoria actual
            if ($line -match "Clock Speed.*MHz.*\(Memory\)" -and $line -notmatch "\[0x") {
                if ($line -match "([\d\.]+)\s+MHz") { 
                    $currentSpeed = [double]$matches[1] 
                    $timingsFound = $true
                }
            }
            # Fallback: buscar en sección Memory
            if (-not $timingsFound -and $line -match "DRAM Frequency.*([\d\.]+)\s+MHz") {
                $currentSpeed = [double]$matches[1]
                $timingsFound = $true
            }
        }
        
        $maxXMP = if ($xmpProfiles.Count -gt 0) { ($xmpProfiles | Sort-Object -Descending)[0] } else { 0 }
        $effectiveSpeed = [math]::Round($currentSpeed * 2, 0)
        
        # Determinar estado XMP (variables separadas)
        if ($maxXMP -eq 0) { 
            $statusText = "Sin XMP"
            $statusColor = "Yellow" 
        } elseif ($currentSpeed -eq 0) {
            $statusText = "Error lectura"
            $statusColor = "Red"
        } elseif ([math]::Abs($effectiveSpeed - $maxXMP) -le 80) { 
            $statusText = "Activado"
            $statusColor = "Green" 
        } else { 
            $statusText = "Desactivado"
            $statusColor = "Red" 
        }

        $line = "RAM | XMP-$maxXMP | Actual: $currentSpeed MHz (x2 = $effectiveSpeed) -> $statusText"
        $script:cpuzInfo = [PSCustomObject]@{ Line = $line; Color = $statusColor }
        # === CONSEJO XMP MEJORADO ===
        $script:xmpAdvice = $null
        if ($statusText -eq "Desactivado" -and $maxXMP -gt 0 -and $script:motherboard -notin "Desconocido", "No disponible") {
            $cleanName = ($script:motherboard -split " ")[0..1] -join " "
            $cleanName = $cleanName -replace '\s*\([^)]*\)', '' -replace '\s+$', ''
            $currentSpeedRounded = [math]::Round($currentSpeed, 0)
            $script:xmpAdvice = "Pierdes hasta 25% FPS + stuttering por RAM lenta ($currentSpeedRounded MHz -> XMP-$maxXMP)`nBuscar en YouTube: `"$cleanName enable XMP`"`nActiva XMP en BIOS (F2/F10/SUPR al encender PC)"
        }

        # === FINAL CPU-Z ===
        Log-Progress "# ----------------------------------------------------" Gray -Subsection
        Log-Progress "# CPU-Z: INFORMACION LEIDA CORRECTAMENTE" Green -Subsection
        Log-Progress "# ----------------------------------------------------" Gray -Subsection

    } catch {
        $script:cpuzInfo = "Error CPU-Z"
        $script:motherboard = "No disponible"
        $script:xmpAdvice = $null
        Log-Progress "ERROR CPU-Z: $($_.Exception.Message)" Red -Error
    }
}

# === AVISO BIOS XMP ===
function Show-XmpWarning {
    if ($script:xmpAdvice) {
        $lines = $script:xmpAdvice -split "`n"
        Write-Host ""
        Write-Host "MUY RECOMENDADO: Activar XMP (perfil RAM)" -ForegroundColor Red
        Write-Host $lines[0] -ForegroundColor Red
        Write-Host $lines[1] -ForegroundColor Yellow
        Write-Host $lines[2] -ForegroundColor Yellow
        Write-Host ""
    }
}

# === GENERAR Y LEER XML DE GPU-Z ===
function Update-GPUZInfo {
    try {
        $scriptPath = $PSScriptRoot
        if (-not $scriptPath) { $scriptPath = (Get-Location).Path }
        $gpuzPath = "$scriptPath\gpuz.exe"
        $xmlPath = "$scriptPath\gpuz.xml"
        $zipUrl = "https://ftp.nluug.nl/pub/games/PC/guru3d/generic/GPU-Z-[Guru3D.com].zip"
        $zipPath = "$scriptPath\gpuz_temp.zip"
		
		$skipGeneration = $false
        if (-not (Test-RebootSinceLastRun) -and (Test-Path $xmlPath)) {
            $fileAge = (Get-Date) - (Get-Item $xmlPath).LastWriteTime
            if ($fileAge.TotalHours -lt 48) {
                Log-Progress "# Reutilizando gpuz.xml existente" Green -Subsection
                $skipGeneration = $true
            }
        }

		if (-not $skipGeneration) {
			# === DESCARGAR Y EXTRAER GPU-Z ===
			if (-not (Test-Path $gpuzPath)) {
				Log-Progress "Descargando GPU-Z..." Yellow
				try {
					Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30
					if (-not (Test-Path $zipPath)) { throw "ZIP no se descargo." }
					Log-Progress "Extrayendo GPU-Z..." Yellow
					$tempExtract = "$scriptPath\gpuz_extract"
					if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
					
					# === EXTRAER ZIP CON FALLBACK ===
					try {
						Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force -ErrorAction Stop
						Log-Progress "Extrayendo GPU-Z con Expand-Archive..." Yellow
					} catch {
						Log-Progress "Expand-Archive no disponible, usando metodo COM..." Yellow
						$shell = New-Object -ComObject Shell.Application
						$zip = $shell.NameSpace($zipPath)
						foreach ($item in $zip.Items()) {
							$shell.NameSpace($tempExtract).CopyHere($item, 0x14)
						}
					}
					
					$exeFile = Get-ChildItem -Path $tempExtract -Filter "GPU-Z.*.exe" -Recurse | Select-Object -First 1
					if (-not $exeFile) { throw "No se encontro GPU-Z.*.exe en el ZIP" }
					Move-Item $exeFile.FullName $gpuzPath -Force
					Remove-Item $tempExtract -Recurse -Force
					Remove-Item $zipPath -Force
					Log-Progress "GPU-Z descargado y extraido correctamente." Green
				}
				catch {
					$script:gpuzInfo = "Error al descargar/extraer GPU-Z: $($_.Exception.Message)"
					Log-Progress "$script:gpuzInfo" Red -Error
					return
				}
			}

			# === INICIO GPU-Z ===
			Log-Progress "# INICIANDO GPU-Z" Cyan -Subsection
			Log-Progress "# ----------------------------------------------------" Gray -Subsection

			# === EJECUTAR GPU-Z ===
			Log-Progress "# Ejecutando GPU-Z..." Cyan -Subsection
			if (Test-Path $xmlPath) { Remove-Item $xmlPath -Force }
			
			$process = Start-Process -FilePath $gpuzPath -ArgumentList "-dump `"$xmlPath`"" -PassThru -WindowStyle Hidden
			if (-not $process) {
				$script:gpuzInfo = "Error: No se pudo iniciar GPU-Z"
				Log-Progress "$script:gpuzInfo" Red -Error
				return
			}

			Log-Progress "# GENERANDO GPUZ.XML" Yellow -Subsection

			# === ESPERA MEJORADA: HASTA </gpuz_dump> ===
			$maxWait = 60
			$xmlReady = $false
			$lastSize = 0
			$stableCount = 0

			for ($i = 0; $i -lt $maxWait; $i++) {
				Start-Sleep -Seconds 1

				# === VERIFICAR SI EL ARCHIVO EXISTE ===
				if (-not (Test-Path $xmlPath)) {
					if ($i % 5 -eq 0) {
						Log-Progress "# Esperando generacion de XML... ($i/$maxWait segundos)" DarkGray -Subsection
					}
					continue
				}

				$fileSize = (Get-Item $xmlPath).Length

				# === VERIFICAR SI EL ARCHIVO TERMINA CON </gpuz_dump> ===
				try {
					# Usar StreamReader para evitar problemas de bloqueo
					$reader = [System.IO.StreamReader]::new($xmlPath)
					$content = $reader.ReadToEnd()
					$reader.Close()

					if ($content -match '</gpuz_dump>\s*$') {
						Log-Progress "# XML COMPLETO: </gpuz_dump> detectado ($i segundos, $fileSize bytes)" Green -Subsection

						# Validar XML
						try {
							[xml]$xmlDoc = $content

							if ($null -eq $xmlDoc.gpuz_dump -or $null -eq $xmlDoc.gpuz_dump.card) {
								Log-Progress "# XML completo pero sin datos de GPU" Yellow -Subsection
								continue
							}

							$valid = $false
							foreach ($c in $xmlDoc.gpuz_dump.card) {
								if (-not [string]::IsNullOrWhiteSpace($c.cardname)) {
									$valid = $true
									break
								}
							}
							if (-not $valid) {
								Log-Progress "# XML sin nombre de GPU valido" Yellow -Subsection
								continue
							}

							$xmlReady = $true
							Log-Progress "# XML VALIDO Y COMPLETO" Green -Subsection

							# Cerrar GPU-Z limpiamente
							if (-not $process.HasExited) {
								Log-Progress "# Cerrando GPU-Z..." DarkGray -Subsection
								$process.CloseMainWindow() | Out-Null
								Start-Sleep -Milliseconds 500
								if (-not $process.HasExited) { 
									$process.Kill()
									Start-Sleep -Milliseconds 300
								}
							}
							break

						} catch {
							Log-Progress "# Error parseando XML completo: $($_.Exception.Message)" Red -Subsection
						}
					}
					else {
						# Aún no termina
						if ($fileSize -eq $lastSize) {
							$stableCount++
							if ($stableCount -gt 5 -and $fileSize -gt 2048) {
								Log-Progress "# Archivo estable pero sin cierre. Forzando lectura..." Yellow -Subsection
								# Intentar parsear de todos modos
								try {
									if ($content -match '<cardname>' -and $content.Length -gt 1000) {
										[xml]$xmlDoc = $content
										if ($xmlDoc.gpuz_dump.card) {
											$xmlReady = $true
											Log-Progress "# XML parcial pero usable" Yellow -Subsection
											if (-not $process.HasExited) { 
												$process.Kill()
												Start-Sleep -Milliseconds 300
											}
											break
										}
									}
								} catch {
									Log-Progress "# Error parseando XML parcial: $($_.Exception.Message)" Red -Subsection
								}
							}
						} else {
							$stableCount = 0
							$lastSize = $fileSize
						}

						if ($i % 5 -eq 0) {
							Log-Progress "# GPU-Z escribiendo... ($fileSize bytes, esperando </gpuz_dump>)" DarkGray -Subsection
						}
					}
				} catch {
					if ($i % 5 -eq 0) {
						Log-Progress "# Leyendo archivo... ($i segundos)" DarkGray -Subsection
					}
				}
			}

			# === SI NO SE PUDO LEER EL XML ===
			if (-not $xmlReady) {
				if (-not $process.HasExited) {
					$process.Kill()
					Start-Sleep -Milliseconds 300
				}
				$script:gpuzInfo = "Error: No se pudo generar XML valido de GPU-Z"
				Log-Progress "$script:gpuzInfo" Red -Error
				return
			}
		}

        Log-Progress "# PROCESANDO INFORMACION DE GPU..." Yellow -Subsection

        # === LEER XML ===
        try {
            [xml]$xml = Get-Content $xmlPath -Raw
            $cards = $xml.gpuz_dump.card

            # CLASIFICAR TODAS LAS GPUs
            $filteredCards = @()
            foreach ($card in $cards) {
                $gpuType = Get-GPUType -gpuName $card.cardname
                $filteredCards += [PSCustomObject]@{
                    Card = $card
                    Type = $gpuType.Type
                    DisplayName = $gpuType.DisplayName
                    ShowDetails = $gpuType.ShowDetails
                }
            }

            $script:gpuzInfo = @()
            foreach ($filteredCard in $filteredCards) {
                $card = $filteredCard.Card
                $name = $filteredCard.DisplayName

                # Línea 1: Nombre de la GPU
                $nameColor = if ($filteredCard.Type -eq "iGPU") { "Yellow" } else { "White" }
                $script:gpuzInfo += [PSCustomObject]@{
                    Line = $name
                    Color = $nameColor
                }

                # Solo mostrar ReBAR y PCIe para GPUs dedicadas
                if ($filteredCard.ShowDetails) {
                    # Línea 2: Estado ReBAR
                    $rebar = if ($card.resizablebar -eq "Enabled") { "Activado" } else { "Desactivado" }
                    $rebarColor = if ($card.resizablebar -eq "Enabled") { "Green" } else { "Red" }
                    $script:gpuzInfo += [PSCustomObject]@{
                        Line = "ReBAR: $rebar"
                        Color = $rebarColor
                    }

                    # Línea 3: Conexión PCIe (solo "actual")
                    $maxMatch = [regex]::Match($card.businterface, "x(\d+)\s+([\d\.]+)")
                    $recWidth = if ($maxMatch.Success) { "x$($maxMatch.Groups[1].Value)" } else { "x?" }
                    $recGenRaw = if ($maxMatch.Success) { [double]$maxMatch.Groups[2].Value } else { 0 }
                    $recGen = if ($recGenRaw -gt 0) { "Gen$([math]::Floor($recGenRaw))" } else { "Gen?" }

                    $curMatch = [regex]::Match($card.businterface, "@\s*x(\d+)\s+([\d\.]+)")
                    $curWidth = if ($curMatch.Success) { "x$($curMatch.Groups[1].Value)" } else { "x?" }
                    $curGenRaw = if ($curMatch.Success) { [double]$curMatch.Groups[2].Value } else { 0 }
                    $curGen = if ($curGenRaw -gt 0) { "Gen$([math]::Floor($curGenRaw))" } else { "Gen?" }

                    # Fallback: usar pcie_current si businterface no tiene @
                    if (-not $curMatch.Success -and $card.pcie_current) {
                        if ($card.pcie_current -match "x\s*(\d+)\s*@?\s*Gen\s*([\d\.]+)") {
                            $curWidth = "x$($matches[1])"
                            $curGenRaw = [double]$matches[2]
                            $curGen = "Gen$([math]::Floor($curGenRaw))"
                        } elseif ($card.pcie_current -match "Gen\s*([\d\.]+)\s*x\s*(\d+)") {
                            $curGenRaw = [double]$matches[1]
                            $curWidth = "x$($matches[2])"
                            $curGen = "Gen$([math]::Floor($curGenRaw))"
                        }
                    }
                    if (-not $curMatch.Success -and $card.pcie_current -match "Gen\s*([\d\.]+)") {
                        $curGen = "Gen$([math]::Floor([double]$matches[1]))"
                    }

                    $actual = "PCIe $curWidth $curGen"
                    $currentWidth = ($curWidth -replace 'x','' -as [int])
                    $optimalWidth = ($recWidth -replace 'x','' -as [int])
                    $currentGen = $curGenRaw
                    $optimalGen = $recGenRaw

                    # Contar SOLO dGPUs
                    $dGPUCount = ($filteredCards | Where-Object { $_.ShowDetails -eq $true }).Count
                    $isMultiGPU = $dGPUCount -gt 1

                    # Calcular ancho de banda
                    $genMultipliers = @{"1.0"=1; "2.0"=2; "3.0"=4; "4.0"=8; "5.0"=16}
                    $currentMultiplier = if ($genMultipliers.ContainsKey("$currentGen")) { $genMultipliers["$currentGen"] } else { 1 }
                    $optimalMultiplier = if ($genMultipliers.ContainsKey("$optimalGen")) { $genMultipliers["$optimalGen"] } else { 1 }
                    $currentBandwidth = $currentWidth * $currentMultiplier
                    $optimalBandwidth = $optimalWidth * $optimalMultiplier
                    $widthOK = $currentWidth -eq $optimalWidth
                    $genOK = $currentGen -eq $optimalGen
                    $bandwidthOK = $currentBandwidth -ge ($optimalBandwidth * 0.5)

                    if ($isMultiGPU -and $optimalWidth -eq 16 -and $currentWidth -eq 8 -and $genOK) {
                        $pcieColor = "Green"
                    } elseif ($isMultiGPU -and $optimalWidth -eq 16 -and $currentWidth -eq 8 -and $currentGen -ge $optimalGen) {
                        $pcieColor = "Green"
                    } elseif ($widthOK -and $genOK) {
                        $pcieColor = "Green"
                    } elseif ($bandwidthOK -and $currentGen -ge $optimalGen) {
                        $pcieColor = "Green"
                    } else {
                        $pcieColor = "Red"
                    }

                    if (-not $genOK) {
                        $actual += " [Gen$currentGen vs Gen$optimalGen]"
                    }

                    $reason = ""
                    if ($pcieColor -eq "Green" -and $isMultiGPU -and $optimalWidth -eq 16 -and $currentWidth -eq 8) {
                        $reason = " (Multi-GPU: x8 normal)"
                    } elseif ($pcieColor -eq "Red") {
                        if ($currentWidth -lt $optimalWidth -and $currentGen -ge $optimalGen) {
                            $reason = " (Ancho reducido: x$currentWidth vs x$optimalWidth)"
                        } elseif ($currentGen -lt $optimalGen) {
                            $reason = " (Gen inferior: Gen$currentGen vs Gen$optimalGen)"
                        } elseif ($currentWidth -ne $optimalWidth) {
                            $reason = " (Ancho incorrecto: x$currentWidth vs x$optimalWidth)"
                        } else {
                            $reason = " (Baja ancho de banda)"
                        }
                    }

                    $script:gpuzInfo += [PSCustomObject]@{
                        Line = "Conexion actual: $actual$reason"
                        Color = $pcieColor
                    }
                }

                # Línea vacía entre GPUs
                $script:gpuzInfo += [PSCustomObject]@{
                    Line = ""
                    Color = "White"
                }
            }

            # Remover última línea vacía
            if ($script:gpuzInfo.Count -gt 0 -and $script:gpuzInfo[-1].Line -eq "") {
                $script:gpuzInfo = $script:gpuzInfo[0..($script:gpuzInfo.Count-2)]
            }
			# === CONSEJO REBAR MEJORADO ===
			$script:rebarYoutube = $null
			$rebarOff = $script:gpuzInfo | Where-Object { $_.Line -match "ReBAR: Desactivado" }
			if ($rebarOff -and $script:motherboard -and $script:motherboard -notmatch "Desconocido|No disponible") {
				# Usar el nombre completo que ya detectó CPU-Z
				$cleanName = $script:motherboard.Trim()
				# Solo quitar paréntesis si los hay y espacios sobrantes
				$cleanName = $cleanName -replace '\s*\([^)]*\)', '' -replace '\s+$', ''
				$script:rebarYoutube = "$cleanName enable Resizable BAR"
			}
            # === FINAL GPU-Z ===
            Log-Progress "# ----------------------------------------------------" Gray -Subsection
            Log-Progress "# GPU-Z: INFORMACION LEIDA CORRECTAMENTE" Green -Subsection
            Log-Progress "# ----------------------------------------------------" Gray -Subsection

			# === MOSTRAR GPUs DETECTADAS AQUÍ ===
			Log-Progress "# GPUs DETECTADAS (GPU-Z)" Cyan -Subsection
			Log-Progress "# -------------------------------------------------------------------" Gray -Subsection
			foreach ($info in $script:gpuzInfo) {
				if ($info.Line.Trim() -ne "" -and $info.Line -notmatch "ReBAR:|Conexion actual:") {
					if ($info.Line -match "^(AMD|NVIDIA|Intel|GeForce|Radeon|Arc)") {
						Log-Progress "# $($info.Line.Trim())" White -Subsection
					}
				}
			}
			Log-Progress "# -------------------------------------------------------------------" Gray -Subsection

        } catch {
            $script:gpuzInfo = "Error procesando XML de GPU-Z: $($_.Exception.Message)"
            Log-Progress "$script:gpuzInfo" Red -Error
        }

    } catch {
        $script:gpuzInfo = "Error GPU-Z: $($_.Exception.Message)"
        Log-Progress "$script:gpuzInfo" Red -Error
    } finally {
        # Limpieza final - asegurarse de que GPU-Z esté cerrado
        try {
            $processes = Get-Process -Name "GPU-Z*" -ErrorAction SilentlyContinue
            foreach ($proc in $processes) {
                if (-not $proc.HasExited) {
                    $proc.Kill()
                    Start-Sleep -Milliseconds 200
                }
            }
        } catch {
            # Ignorar errores en limpieza
        }
    }
}

# === AVISO BIOS REBAR ===
function Show-RebarWarning {
    if ($script:rebarYoutube) {
        Write-Host ""
        Write-Host "MUY RECOMENDADO: Activar Resizable BAR (ReBAR)" -ForegroundColor Red
        Write-Host "Pierdes hasta 20% FPS en juegos modernos" -ForegroundColor Red
        Write-Host "Buscar en YouTube: `"$script:rebarYoutube`"" -ForegroundColor Yellow
        Write-Host "Activa ReBAR en BIOS (F2/F10/SUPR al encender PC)" -ForegroundColor Yellow
        Write-Host ""
    }
}

# === DETECCIÓN FINAL DE HARDWARE ===
function GPU-CheckGPUZorRegister {
	$script:gpus = Get-AllAMDGPUs
	$script:hasAMD = $false
	$script:hasNVIDIA = $false

	if ($script:gpuzInfo) {
		foreach ($info in $script:gpuzInfo) {
			if ($info.Line -match "AMD Radeon RX [56789]") { $script:hasAMD = $true }
			if ($info.Line -match "GeForce|RTX|GTX|TITAN|Quadro") { $script:hasNVIDIA = $true }
		}
	}

	# Fallback: si GPU-Z falló, usar registro
	if (-not $script:hasAMD) { $script:hasAMD = (Get-AllAMDGPUs).Count -gt 0 }
	if (-not $script:hasNVIDIA) {
		$nvidiaKeys = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d+$" }
		foreach ($key in $nvidiaKeys) {
			$desc = (Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue).DriverDesc
			if ($desc -match "NVIDIA GeForce|RTX|GTX|TITAN") {
				$script:hasNVIDIA = $true
				break
			}
		}
	}
	
	Log-Progress "GPU Detectada: AMD=$script:hasAMD | NVIDIA=$script:hasNVIDIA" Cyan
}

# === DESCARGA + PRIMERA LECTURA - NVIDIA INSPECTOR ===
function Initialize-NVIDIAInspector {
    if (-not $script:hasNVIDIA) {
        $script:nvidiaShaderCache = "No NVIDIA"
        return
    }

    $scriptPath = $PSScriptRoot
    if (-not $scriptPath) { $scriptPath = (Get-Location).Path }
    $zipUrl = "https://github.com/LetalDark/Optimizador/releases/download/1.0-nspector/nspector.zip"
    $zipPath = "$scriptPath\nspector.zip"
    $exeName = "nvidiaProfileInspector.exe"
    $exePath = "$scriptPath\$exeName"
    $tempExtract = "$scriptPath\nspector_extract"

    # === SECCIÓN VISUAL ===
    Log-Progress "# # ----------------------------------------------------" Gray -Subsection
    Log-Progress "# # INICIANDO NVIDIA Profile Inspector" Cyan -Subsection
    Log-Progress "# # ----------------------------------------------------" Gray -Subsection

    # === SI NO EXISTE, DESCARGAR Y EXTRAER ===
    if (-not (Test-Path $exePath)) {
        # === LIMPIAR ===
        foreach ($p in @($zipPath)) { if (Test-Path $p) { Remove-Item $p -Force } }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }

        # === DESCARGAR ===
        try {
            Log-Progress "Descargando NVIDIA Profile Inspector..." Yellow
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            Log-Progress "Descargado OK" Green
        } catch {
            Log-Progress "ERROR DESCARGA" Red -Error
            $script:nvidiaShaderCache = "Error descarga"
            return
        }

        # === EXTRAER ===
        try {
            Log-Progress "Extrayendo..." Yellow
            Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force -ErrorAction Stop
            Log-Progress "Extraido con Expand-Archive" Green
        } catch {
            Log-Progress "Expand-Archive fallo, usando COM Shell..." Yellow
            try {
                $shell = New-Object -ComObject Shell.Application
                $zip = $shell.NameSpace($zipPath)
                foreach ($item in $zip.Items()) {
                    $shell.NameSpace($tempExtract).CopyHere($item, 0x14)
                }
                Log-Progress "Extraido con COM Shell" Green
            } catch {
                Log-Progress "ERROR EXTRACCION" Red -Error
                $script:nvidiaShaderCache = "Error extraccion"
                return
            }
        }

        # === MOVER ARCHIVOS ===
        $files = Get-ChildItem -Path $tempExtract -File
        foreach ($file in $files) {
            Move-Item $file.FullName "$scriptPath\$($file.Name)" -Force
        }
        Log-Progress "Listo: $exeName + config + XML" Green

        # === LIMPIAR ===
        Remove-Item $zipPath -Force
        Remove-Item $tempExtract -Recurse -Force
    } else {
        Log-Progress "Ya descargado: $exeName" Gray
    }

    # === PRIMERA LECTURA ===
    Log-Progress "Leyendo Shader Cache..." Yellow
    Read-NVIDIAShaderCache
    if ($script:nvidiaShaderCache -is [PSCustomObject]) {
        Log-Progress "Shader Cache: $($script:nvidiaShaderCache.Text) ($($script:nvidiaShaderCache.Hex))" $script:nvidiaShaderCache.Color
    } else {
        Log-Progress "Shader Cache no detectado" Red
    }
}

# === LEER NVIDIA SHADER CACHE ===
function Read-NVIDIAShaderCache {
    $exePath = "$PSScriptRoot\nvidiaProfileInspector.exe"
    if (-not (Test-Path $exePath)) {
        $script:nvidiaShaderCache = "No detectado"
        return
    }

    $output = ""
    try {
        $temp = "$PSScriptRoot\nspector_tmp.txt"
        Start-Process -FilePath $exePath -ArgumentList '-p "Base Profile" --list-settings' -Wait -NoNewWindow -RedirectStandardOutput $temp -ErrorAction Stop | Out-Null
        $output = Get-Content $temp -Raw -ErrorAction SilentlyContinue
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    } catch { }

    $line = $output | Where-Object { $_ -match "Shader Cache - Cache Size" } | Select-Object -First 1
    if (-not $line -or $line -notmatch 'Cache Size\s+([^\s]+)\s+0x([0-9A-F]{8})') {
        $script:nvidiaShaderCache = "No detectado"
        return
    }

    $sizeText = $matches[1]
    $hexValue = "0x" + $matches[2].ToUpper()

	# === COLOR: VERDE SI ≥10GB o Unlimited, ROJO SI <10GB ===
	$isGood = ($sizeText -eq "Unlimited") -or ($sizeText -match "GB" -and [int]($sizeText -replace "GB","") -ge 10)
	$color = if ($isGood) { "Green" } else { "Red" }

    $script:nvidiaShaderCache = [PSCustomObject]@{
        Line = "Shader Cache -> $sizeText"
        Color = $color
        Hex = $hexValue
        Text = $sizeText
    }
}

# === APLICAR NVIDIA SHADER CACHE ===
function Set-NVIDIAShaderCache {
    param([string]$SizeName)
    $exePath = "$PSScriptRoot\nvidiaProfileInspector.exe"
    if (-not (Test-Path $exePath)) {
        Write-Host "`nERROR: nvidiaProfileInspector.exe no encontrado" -ForegroundColor Red
        return $false
    }

    $sizes = @{
        "Off"="0x00000000"; "128MB"="0x00000080"; "256MB"="0x00000100"; "512MB"="0x00000200";
        "1GB"="0x00000400"; "4GB"="0x00001000"; "5GB"="0x00001400"; "8GB"="0x00002000";
        "10GB"="0x00002800"; "100GB"="0x00019000"; "Unlimited"="0xFFFFFFFF"
    }
    if (-not $sizes.ContainsKey($SizeName)) { return $false }

    $desiredHex = $sizes[$SizeName]

    # === LEER VALOR ACTUAL ===
    Read-NVIDIAShaderCache

    # === 10GB, 100GB y Unlimited se consideran "igual o mejor" → no tocar ===
    if ($script:nvidiaShaderCache.Text -in @("10GB", "100GB", "Unlimited")) {
        Write-Host "`nShader Cache NVIDIA: YA esta en $($script:nvidiaShaderCache.Text) (10GB o superior)" -ForegroundColor Gray
        return $false
    }

    # === SI LLEGA AQUÍ → SÍ HAY QUE CAMBIAR ===
    $cmd = "& `"$exePath`" -p `"Base Profile`" --set `"00AC8497=$desiredHex`""
    try {
        Invoke-Expression $cmd | Out-Null
        Write-Host "`nShader Cache: $SizeName aplicado" -ForegroundColor Green
        $script:changesMade = $true
        return $true
    } catch {
        Write-Host "`nERROR al aplicar Shader Cache NVIDIA" -ForegroundColor Red
        return $false
    }
}

# === SISTEMA DE LOG VISUAL CENTRALIZADO (COMPATIBLE PS 5.1) ===
function Log-Progress {
    param(
        [string]$Message,
        [string]$Color = "White",
        [switch]$Error,
        [switch]$Section,
        [switch]$Subsection
    )
    $prefix = if ($Error) { "[ERROR] " } else { "[INFO]  " }
    
    # LIMPIEZA DE ACENTOS
    $clean = $Message -replace '[^\x00-\x7F]', ''
    $clean = $clean -replace 'Ã³','o' -replace 'Ã¡','a' -replace 'Ã©','e' -replace 'Ã­','i' -replace 'Ã±','n'

    $colorMap = @{
        "Green"="Green"; "Red"="Red"; "Yellow"="Yellow"; "Cyan"="Cyan"; "White"="White"; "Gray"="DarkGray"; "Magenta"="Magenta"
    }
    $safeColor = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { "White" }

    if ($Section) {
        Write-Host "$clean" -ForegroundColor $safeColor
    } elseif ($Subsection) {
        Write-Host "$prefix# $clean" -ForegroundColor $safeColor
    } else {
        Write-Host "$prefix$clean" -ForegroundColor $safeColor
    }
}

# === CARGA VISUAL LIMPIA (SOLO NOMBRES GPU) ===
function Show-LoadingProcess {
    Write-Host "# ===================================================================" -ForegroundColor Cyan
    Write-Host "# INICIANDO OPTIMIZADOR DE RENDIMIENTO" -ForegroundColor White
    Write-Host "# ===================================================================" -ForegroundColor Cyan
    Write-Host "# CARGA COMPLETADA" -ForegroundColor Cyan
    Write-Host "# ===================================================================`n" -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# === FUNCIÓN GLOBAL: OBTENER PLANES DE ENERGÍA CON UTF8 Y LIMPIEZA ===
function Get-PowerPlans {
    $plansRaw = powercfg -l | Out-String -Stream
    $plans = @()
    foreach ($line in $plansRaw) {
        if ($line -match '([a-f0-9-]{36})\s+(.+?)(?:\s+\(.*\))?$') {
            $guid = $matches[1].Trim()
            $rawName = $matches[2].Trim()
            # QUITAR EL * DEL PLAN ACTIVO
            $name = $rawName -replace '\*$', ''
            # CONVERTIR UTF-8 → CORRECTO
            $name = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($name))
            $isActive = $line -match '\*'
            $plans += [PSCustomObject]@{
                Guid     = $guid
                Name     = $name
                IsActive = $isActive
            }
        }
    }
    return $plans
}

# === GESTIONAR MODO MAXIMO RENDIMIENTO (CON LIMPIEZA DUPLICADOS) ===
function Set-MaximoRendimiento {
    Write-Host "Procesando Maximo rendimiento..." -ForegroundColor Yellow

    $performanceNames = @(
        "Maximo rendimiento", "Ultimate Performance",
        "Alto rendimiento", "High performance", "Rendimiento elevado"
    )

    # Obtener planes
    $plans = Get-PowerPlans
    if (-not $plans) {
        Write-Host "ERROR: No se pudieron leer los planes." -ForegroundColor Red
        return $false
    }

    # Detectar plan activo
    $activeOutput = powercfg -getactivescheme | Out-String
    $activeGuid = $null
    if ($activeOutput -match '([a-f0-9-]{36})') { $activeGuid = $matches[1] }

    # Buscar plan principal
    $targetPlan = $null
    foreach ($plan in $plans) {
        $cleanName = $plan.Name -replace '[^\x00-\x7F]', 'a'
        foreach ($name in $performanceNames) {
            $escapedName = [regex]::Escape($name) -replace '[^\x00-\x7F]', 'a'
            if ($cleanName -match $escapedName) {
                $targetPlan = $plan
                break
            }
        }
        if ($targetPlan) { break }
    }

    # === SI YA ESTÁ PERFECTO (activo + sin duplicados) → NO HACEMOS NADA ===
    if ($targetPlan -and $targetPlan.Guid -eq $activeGuid) {
        # Verificamos si hay duplicados
        $duplicatePlans = $plans | Where-Object {
            $cleanDupName = $_.Name -replace '[^\x00-\x7F]', 'a'
            foreach ($name in $performanceNames) {
                if ($cleanDupName -match [regex]::Escape($name) -and $_.Guid -ne $targetPlan.Guid) {
                    return $true
                }
            }
            $false
        }

        if ($duplicatePlans.Count -eq 0) {
            Write-Host "Maximo rendimiento YA ACTIVO y sin duplicados: $($targetPlan.Name)" -ForegroundColor Green
            return $true
        }
    }

    # === SI LLEGA AQUÍ → SÍ HAY QUE HACER ALGO (limpiar, activar o crear) ===
    $script:changesMade = $true

    # === LIMPIEZA DE DUPLICADOS (SEGURA) ===
    $activeOutput = powercfg -getactivescheme | Out-String
    $activeGuid = $null
    if ($activeOutput -match '([a-f0-9-]{36})') { $activeGuid = $matches[1] }

    $duplicatePlans = $plans | Where-Object {
        $cleanDupName = $_.Name -replace '[^\x00-\x7F]', 'a'
        foreach ($name in $performanceNames) {
            if ($cleanDupName -match [regex]::Escape($name) -and $_.Guid -ne $targetPlan.Guid) {
                return $true
            }
        }
        $false
    }

    $deletedCount = 0
    foreach ($dup in $duplicatePlans) {
        if ($dup.Guid -eq $activeGuid) {
            Write-Host "Saltando duplicado ACTIVO: $($dup.Name)" -ForegroundColor DarkGray
            continue
        }
        try {
            powercfg -delete $dup.Guid | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Eliminado duplicado: $($dup.Name)" -ForegroundColor Cyan
                $deletedCount++
            }
        } catch {
            Write-Host "ADVERTENCIA: No se pudo borrar $($dup.Name)" -ForegroundColor Yellow
        }
    }
    if ($deletedCount -gt 0) {
        Write-Host "Limpiados $deletedCount planes duplicados" -ForegroundColor Green
        Start-Sleep -Seconds 2
        $plans = Get-PowerPlans
    }

    # Activar plan principal (si existe)
    if ($targetPlan -and $targetPlan.Guid -ne $activeGuid) {
        Write-Host "Activando: $($targetPlan.Name)" -ForegroundColor Yellow
        powercfg /s $targetPlan.Guid | Out-Null
        Write-Host "Maximo rendimiento ACTIVADO" -ForegroundColor Green
        return $true
    }

    # Crear nuevo
    Write-Host "Creando nuevo plan..." -ForegroundColor Yellow
    $result = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No se pudo crear (Windows no lo soporta)" -ForegroundColor Red
        return $false
    }

    Start-Sleep -Seconds 4
    $plans = Get-PowerPlans
    $newPlan = $plans | Where-Object {
        $n = $_.Name -replace '[^\x00-\x7F]', 'a'
        $n -match "Ultimate|Maximo"
    } | Select-Object -Last 1

    if ($newPlan) {
        powercfg /s $newPlan.Guid | Out-Null
        Write-Host "Nuevo plan CREADO Y ACTIVADO: $($newPlan.Name)" -ForegroundColor Green
        return $true
    }

    Write-Host "Plan creado pero no activado automaticamente" -ForegroundColor Yellow
    return $false
}

# === TEST FRECUENCIA RATON ===
function Test-MousePollingRate {
    Write-Host "`nIniciando test de frecuencia de raton..." -ForegroundColor Yellow
    Write-Host "Mueve el raton en CIRCULOS rapidos durante 8 segundos" -ForegroundColor Cyan
    Write-Host "IMPORTANTE: Movimientos rapidos y constantes!" -ForegroundColor Red
    Write-Host "El test comenzara automaticamente en 2 segundos..." -ForegroundColor Green
    Start-Sleep -Seconds 2
    
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    # Variables para capturar movimientos
    $mouseTimes = New-Object System.Collections.Generic.List[double]
    $mouseMoveCount = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    # Crear formulario grande 1200x800
    $form = New-Object System.Windows.Forms.Form
    $form.TopMost = $true
    $form.Text = "TEST RATON - Mueve en CIRCULOS RAPIDOS - 8 segundos"
    $form.Width = 1200
    $form.Height = 800
    $form.BackColor = [System.Drawing.Color]::LightBlue
    $form.FormBorderStyle = "FixedDialog"
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    
    # Etiqueta principal grande
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "MOVIMIENTOS RAPIDOS EN CIRCULOS`n8 SEGUNDOS`nFrecuencia: Calculando..."
    $label.Size = New-Object System.Drawing.Size(1100, 200)
    $label.Location = New-Object System.Drawing.Point(50, 50)
    $label.Font = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::DarkBlue
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($label)
    
    # Etiqueta de contador
    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Text = "Movimientos: 0"
    $countLabel.Size = New-Object System.Drawing.Size(1100, 50)
    $countLabel.Location = New-Object System.Drawing.Point(50, 300)
    $countLabel.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Regular)
    $countLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    $countLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($countLabel)
    
    # Etiqueta de tiempo
    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = "Tiempo restante: 8 segundos"
    $timeLabel.Size = New-Object System.Drawing.Size(1100, 50)
    $timeLabel.Location = New-Object System.Drawing.Point(50, 350)
    $timeLabel.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Regular)
    $timeLabel.ForeColor = [System.Drawing.Color]::DarkRed
    $timeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($timeLabel)
    
	# Evento de movimiento del raton - VERSION MEJORADA
	$script:mouseMoveCount = 0
	$lastTime = 0
	$mouseMoveHandler = {
		$mouseTimes.Add($sw.Elapsed.TotalMilliseconds)
		$script:mouseMoveCount++
		$sw.Restart()   # ← Aquí pierdes el tiempo real entre eventos
	}
	$form.Add_MouseMove($mouseMoveHandler)

	# Timer para cerrar después de 8 segundos
	$timer = New-Object System.Windows.Forms.Timer
	$timer.Interval = 8000
	$timer.Add_Tick({
		$timer.Stop()
		$updateTimer.Stop()
		$form.Close()
	})

	# Timer para actualizar UI cada 100ms (no cada movimiento)
	$updateTimer = New-Object System.Windows.Forms.Timer
	$updateTimer.Interval = 100
	$remainingTime = 8
	$startTime = [System.Diagnostics.Stopwatch]::StartNew()
	$updateTimer.Add_Tick({
		# Calcular tiempo restante basado en el stopwatch real
		$elapsed = $startTime.Elapsed.TotalSeconds
		$remainingTime = [math]::Max(0, [math]::Ceiling(8 - $elapsed))
		
		# Actualizar labels
		$countLabel.Text = "Movimientos: $script:mouseMoveCount"
		$timeLabel.Text = "Tiempo restante: $remainingTime segundos"
		
		# Cambiar color cuando quede poco tiempo
		if ($remainingTime -le 3) {
			$timeLabel.ForeColor = [System.Drawing.Color]::Red
		}
	})

	# Iniciar todo
	$form.Add_Shown({
		$form.Activate()
		$timer.Start()
		$updateTimer.Start()
		$sw.Restart()
		$startTime.Restart()
	})
    
    # Mostrar formulario modal
    $null = $form.ShowDialog()
    
    # Detener timers por si acaso
    $timer.Stop()
    $updateTimer.Stop()
    
    # Procesar resultados
    Write-Host "`nProcesando resultados..." -ForegroundColor Yellow
    
    # Filtrar outliers y calcular
    $validTimes = $mouseTimes | Where-Object { $_ -gt 0 -and $_ -lt 20 }
    
    if ($validTimes.Count -gt 10) {
        $avg = ($validTimes | Measure-Object -Average).Average
        $rate = [Math]::Round(1000 / $avg, 0)
        
        # Suavizado: tomar percentil 25 para evitar picos altos
        $sortedTimes = $validTimes | Sort-Object
        $percentile25 = $sortedTimes[[Math]::Floor($sortedTimes.Count * 0.25)]
        $rateSmoothed = [Math]::Round(1000 / $percentile25, 0)
        
        # Ajustar a valores estandar comunes
        $commonRates = @(125, 250, 500, 1000)
        $closestRate = $commonRates | Sort-Object { [Math]::Abs($_ - $rateSmoothed) } | Select-Object -First 1
        
        $script:mouseHz = $closestRate
        $script:mouseTested = $true
        
        Write-Host "`nTEST COMPLETADO" -ForegroundColor Green
        Write-Host "Frecuencia de sondeo: $closestRate Hz" -ForegroundColor Green
        Write-Host "Movimientos detectados: $($validTimes.Count)" -ForegroundColor DarkGray
        Write-Host "Intervalo promedio: $([Math]::Round($avg, 2)) ms" -ForegroundColor DarkGray
        
        # Diagnostico
        if ($closestRate -ge 1000) {
            Write-Host "`nCONSEJO: Para evitar stuttering, configura tu raton a 500Hz o menos" -ForegroundColor Yellow
            Write-Host "Usa el software de tu raton para cambiar la frecuencia" -ForegroundColor Yellow
        }
        
        return $true
    } else {
        $script:mouseHz = $null
        $script:mouseTested = $false
        Write-Host "`nERROR: Pocos movimientos detectados ($($validTimes.Count)). Repite con movimientos mas rapidos." -ForegroundColor Red
        return $false
    }
}

# === DETECTAR ACELERACION MOUSE ===
function Get-MouseAccelStatus {
    $regPath = "HKCU:\Control Panel\Mouse"
    $accel = Get-ItemProperty -Path $regPath -Name "MouseSpeed" -ErrorAction SilentlyContinue
    $threshold = Get-ItemProperty -Path $regPath -Name "MouseThreshold1" -ErrorAction SilentlyContinue
    $threshold2 = Get-ItemProperty -Path $regPath -Name "MouseThreshold2" -ErrorAction SilentlyContinue
    $speed = Get-ItemProperty -Path $regPath -Name "MouseSensitivity" -ErrorAction SilentlyContinue

    $isOff = ($accel.MouseSpeed -eq "0") -and ($threshold.MouseThreshold1 -eq "0") -and ($threshold2.MouseThreshold2 -eq "0")
    $sensOK = ($speed.MouseSensitivity -eq "10")  # 6/11 = 10 en registro

    return @{
        Estado = if ($isOff -and $sensOK) { "Desactivado" } else { "Activado" }
        Color = if ($isOff -and $sensOK) { "Green" } else { "Red" }
        Recomendado = "Desactivado"
    }
}

# === ALTERNAR ACELERACION MOUSE ===
function Toggle-MouseAcceleration {
	$script:changesMade = $true
    $regPath = "HKCU:\Control Panel\Mouse"
    $current = Get-MouseAccelStatus

    if ($current.Estado -eq "Desactivado") {
        # ACTIVAR (volver a Windows default)
        Set-ItemProperty -Path $regPath -Name "MouseSpeed" -Value "1" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseThreshold1" -Value "6" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseThreshold2" -Value "10" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseSensitivity" -Value "10" -Type String
        Write-Host "`nAceleracion del mouse: ACTIVADA (Windows default)" -ForegroundColor Yellow
    } else {
        # DESACTIVAR (gaming mode)
        Set-ItemProperty -Path $regPath -Name "MouseSpeed" -Value "0" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseThreshold1" -Value "0" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseThreshold2" -Value "0" -Type String
        Set-ItemProperty -Path $regPath -Name "MouseSensitivity" -Value "10" -Type String
        Write-Host "`nAceleracion del mouse: DESACTIVADA (Gaming Mode)" -ForegroundColor Green
        Write-Host "   + Aim consistente en shooters" -ForegroundColor Cyan
        Write-Host "   + Muscle memory 100% real" -ForegroundColor Cyan
    }
}

# === DETECTAR TIPO DE GPU ===
function Get-GPUType {
    param([string]$gpuName)
    
    $iGPUPatterns = @(
        @{Pattern="Intel HD Graphics"; Type="iGPU"},
        @{Pattern="Intel UHD Graphics"; Type="iGPU"}, 
        @{Pattern="Iris Xe Graphics"; Type="iGPU"},
        @{Pattern="Iris Plus Graphics"; Type="iGPU"},
        @{Pattern="Radeon Vega"; Type="iGPU"},
        @{Pattern="Radeon HD"; Type="iGPU"},
        @{Pattern="Radeon.*Graphics"; Type="iGPU"},
        @{Pattern="Qualcomm.*Adreno"; Type="iGPU"},
        @{Pattern="Adreno.*GPU"; Type="iGPU"},
        @{Pattern="Graphics"; Type="iGPU"}
    )
    
    $dedicatedPatterns = @(
        @{Pattern="RX"; Type="dGPU"},
        @{Pattern="RTX"; Type="dGPU"},
        @{Pattern="GTX"; Type="dGPU"},  
        @{Pattern="Radeon VII"; Type="dGPU"},
        @{Pattern="Radeon Pro"; Type="dGPU"}
    )
    
    # Convertir a minúsculas para comparación case-insensitive
    $gpuNameLower = $gpuName.ToLower()
    
    # Si coincide con algún patrón de dedicada → dGPU
    foreach ($pattern in $dedicatedPatterns) {
        if ($gpuNameLower -match $pattern.Pattern.ToLower()) {
            return @{Type="dGPU"; DisplayName=$gpuName; ShowDetails=$true}
        }
    }
    
    # Si coincide con algún patrón de iGPU → iGPU
    foreach ($pattern in $iGPUPatterns) {
        if ($gpuNameLower -match $pattern.Pattern.ToLower()) {
            return @{Type="iGPU"; DisplayName="$gpuName (Integrada)"; ShowDetails=$false}
        }
    }
    
    # Por defecto, asumir que es dedicada
    return @{Type="dGPU"; DisplayName=$gpuName; ShowDetails=$true}
}

# === DETECTAR SOLO AMD RADEON RX ===
function Get-AllAMDGPUs {
    $amdGPUs = @()
    $keys = Get-ChildItem $reg3Base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d+$" }
    foreach ($key in $keys) {
        try {
            $driverDesc = Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue
            $umdPath = "$($key.PSPath)\UMD"
            if ($driverDesc -and $driverDesc.DriverDesc -match "^AMD Radeon RX [56789]" -and (Test-Path $umdPath)) {
                $cleanName = $driverDesc.DriverDesc -replace "AMD Radeon ", "" -replace " Graphics.*", ""
                $amdGPUs += [PSCustomObject]@{
                    Path = $key.PSPath
                    UMD = $umdPath
                    Name = $cleanName
                }
            }
        } catch { }
    }
    return $amdGPUs | Sort-Object Name
}

# === APLICAR SHADER CACHE (SOLO AMD RX) ===
function Apply-ShaderCacheToAll {
    param([byte[]]$Value)
    $gpus = Get-AllAMDGPUs
    $applied = 0
    foreach ($gpu in $gpus) {
        # ← AÑADIR ESTO:
        if ($gpu.Name -notmatch "RX [56789]") { continue }
        # ← FIN
        try {
            if (-not (Test-Path $gpu.UMD)) {
                New-Item -Path $gpu.UMD -Force | Out-Null
            }
            Set-ItemProperty -Path $gpu.UMD -Name $reg3Name -Value $Value -Type Binary -Force | Out-Null
            $applied++
			$script:changesMade = $true
        } catch {
            Log-Progress "ERROR Shader Cache [$($gpu.Name)]: $($_.Exception.Message)" Red
        }
    }
    return $applied
}

# === LIMPIEZA DE CACHE GPU (AMD / NVIDIA) ===
function Clear-GPUCache {
    param(
        [ValidateSet("AMD", "NVIDIA")] [string]$Vendor
    )
    $cacheBackupPath = "$script:backupPath\$($Vendor)_Cache_Backup"
    New-Item -Path $cacheBackupPath -ItemType Directory -Force | Out-Null
    $users = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notmatch "Public|Default" }
    $totalCopied = 0
    foreach ($user in $users) {
        $vendorPath = if ($Vendor -eq "AMD") {
            "$($user.FullName)\AppData\Local\AMD"
        } else {
            "$($user.FullName)\AppData\Local\NVIDIA"
        }
        if (Test-Path $vendorPath) {
            $cacheFolders = Get-ChildItem $vendorPath -Directory | Where-Object {
                $_.Name -match "cache" -and $_.Name -notmatch "Backup"
            }
            foreach ($folder in $cacheFolders) {
                $dest = "$cacheBackupPath\$($user.Name)_$($folder.Name)"
                try {
                    Copy-Item $folder.FullName $dest -Recurse -Force -ErrorAction SilentlyContinue
                    $totalCopied++
                    Remove-Item $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                } catch { }
            }
        }
    }
    if ($totalCopied -gt 0) {
        Write-Host "`nCache ${Vendor}: $totalCopied carpetas respaldadas y eliminadas" -ForegroundColor Green
        Write-Host " Backup: $cacheBackupPath" -ForegroundColor DarkGray
    } else {
        Write-Host "`nNo se encontró cache ${Vendor}" -ForegroundColor Yellow
    }
}

# === ANALIZAR ESPACIO EN DISCO ===
function Get-DiskSpaceInfo {
    $systemDrive = $env:SystemDrive  # Normalmente C:
    $allDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }
    $results = @()

    foreach ($drive in $allDrives) {
        try {
            $free = $drive.Free
            $used = $drive.Used
            $total = $free + $used
            $percentFree = [math]::Round(($free / $total) * 100, 1)
            $percentUsed = [math]::Round(($used / $total) * 100, 1)

            $color = if ($percentFree -lt 20) { "Red" } elseif ($percentFree -lt 40) { "Yellow" } else { "Green" }

            $results += [PSCustomObject]@{
                Drive       = $drive.Name
                TotalGB     = [math]::Round($total / 1GB, 1)
                FreeGB      = [math]::Round($free / 1GB, 1)
                UsedGB      = [math]::Round($used / 1GB, 1)
                PercentFree = $percentFree
                PercentUsed = $percentUsed
                Color       = $color
                IsSystem    = ($drive.Root -eq "$systemDrive\")
            }
        } catch { }
    }

    $script:systemDisk = $results | Where-Object { $_.IsSystem } | Select-Object -First 1
    $script:allDisks = $results
}

# === OBTENER RAM ===
function Get-PhysicalRAM {
    try {
        $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
        return [math]::Round($ram / 1GB, 2)
    } catch {
        return 0
    }
}

# === CONFIGURAR LA MEMORIA VIRTUAL ===
function Configure-CustomPagefile {
    param([switch]$Silent)
    $physicalRAM = Get-PhysicalRAM
    $ramGB = [int]$physicalRAM
    if ($ramGB -ge ($Global:TargetRAM / 1GB)) {
        Log-Progress "RAM suficiente ($ramGB GB). No se necesita pagefile extra." Gray
        return
    }

    $neededGB = ($Global:TargetRAM / 1GB) - $ramGB
    $minSizeMB = [int]($neededGB * 1024)
    $maxSizeMB = $minSizeMB * 2

    Log-Progress "RAM fisica: $ramGB GB. Objetivo: $($Global:TargetRAM / 1GB) GB" Yellow
    Log-Progress "Se necesita al menos $neededGB GB de memoria virtual" Yellow
    Log-Progress "Config: Min $minSizeMB MB | Max $maxSizeMB MB" Cyan

    # === OBTENER SSD VÁLIDOS ===
    $ssdDisks = Get-PhysicalDisk | Where-Object { $_.MediaType -eq "SSD" -and $_.OperationalStatus -eq "OK" }
    if (-not $ssdDisks) {
        Log-Progress "No se encontraron discos SSD." Red
        return
    }

    $validDrives = @()
    foreach ($disk in $ssdDisks) {
        $partitions = Get-Partition -DiskNumber $disk.DeviceId -ErrorAction SilentlyContinue
        foreach ($part in $partitions) {
            $volume = Get-Volume -Partition $part -ErrorAction SilentlyContinue
            if ($volume -and $volume.DriveLetter -and $volume.FileSystem -eq "NTFS") {
                $driveLetter = "$($volume.DriveLetter):"
                $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 1)
                if ($freeGB -ge ($neededGB * 2)) {
                    $validDrives += [PSCustomObject]@{
                        Letter = $driveLetter
                        FreeGB = $freeGB
                        Disk   = $disk.FriendlyName
                    }
                }
            }
        }
    }
    if ($validDrives.Count -eq 0) {
        Log-Progress "Ningun SSD tiene suficiente espacio libre ($($neededGB * 2) GB requeridos)." Red
        return
    }

    # === SELECCIONAR DISCO ===
    if (-not $Silent) {
        Write-Host "`nSelecciona unidad SSD para pagefile:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $validDrives.Count; $i++) {
            $d = $validDrives[$i]
            Write-Host " $($i+1) - $($d.Letter) ($($d.FreeGB) GB libre) - $($d.Disk)" -ForegroundColor White
        }
        Write-Host " S - Salir" -ForegroundColor Gray
        do { $choice = (Read-Host "`nElige 1-$($validDrives.Count) o S").ToUpper() }
        while ($choice -notin 1..$validDrives.Count -and $choice -ne "S")
        if ($choice -eq "S") { return }
        $selected = $validDrives[$choice - 1]
    } else {
        $selected = $validDrives | Sort-Object FreeGB -Descending | Select-Object -First 1
        Write-Host "Auto: Usando $($selected.Letter) ($($selected.FreeGB) GB libre)" -ForegroundColor Cyan
    }

    $pagefilePath = "$($selected.Letter)\pagefile.sys"
    $desiredValue = "$pagefilePath $minSizeMB $maxSizeMB"

    # === COMPROBAR SI YA ESTÁ CONFIGURADO ASÍ ===
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    $currentPaging = (Get-ItemProperty $regPath -Name "PagingFiles" -ErrorAction SilentlyContinue).PagingFiles
    $currentString = ($currentPaging -join "`n").Trim()

    if ($currentString -eq $desiredValue.Trim()) {
        Write-Host "`nPagefile YA esta correctamente configurado en $($selected.Letter)" -ForegroundColor Gray
        Write-Host " Min: $minSizeMB MB | Max: $maxSizeMB MB" -ForegroundColor Gray
        return  # ← NO marcamos cambio
    }

    # === SI LLEGA AQUÍ → SÍ HAY QUE CAMBIAR ===
    $script:changesMade = $true   # ← Solo aquí, cuando realmente cambia algo

    # Backup (solo la primera vez)
    if (-not $script:pagefileBackupDone -and $currentPaging) {
        $backupFile = "$script:backupPath\pagefile_backup.reg"
        "Windows Registry Editor Version 5.00`n`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management]`n`"PagingFiles`"=`"$($currentPaging -join "`n")`"" | Out-File $backupFile -Encoding ASCII
        Log-Progress "Backup de pagefile guardado" Green
        $script:pagefileBackupDone = $true
    }

    # Desactivar gestión automática
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $computer.AutomaticManagedPagefile = $false
        Set-CimInstance -CimInstance $computer | Out-Null
    } catch { Log-Progress "Error desactivando gestion automatica" Red }

    # Aplicar nuevo pagefile
    Set-ItemProperty -Path $regPath -Name "PagingFiles" -Value $desiredValue -Type MultiString -Force | Out-Null

    # Limpiar pagefile anterior en C: (si existe y no es el seleccionado)
    $oldPagefile = "C:\pagefile.sys"
    if (Test-Path $oldPagefile -and $selected.Letter -ne "C:") {
        try { Remove-Item $oldPagefile -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host "`nPagefile configurado en $($selected.Letter)" -ForegroundColor Green
    Write-Host " Cantidad: $minSizeMB MB - $maxSizeMB MB" -ForegroundColor Cyan
    Write-Host " SSD: $($selected.Disk)" -ForegroundColor Gray
    Write-Host " REINICIA para aplicar." -ForegroundColor Red
    Start-Sleep -Seconds 2
}

# === MODO AUTOMÁTICO / MANUAL ===
function Start-AutoMode {
    Write-Host "`nMODO AUTOMATICO: Aplicando configuracion recomendada..." -ForegroundColor Cyan

    # 1. DirectStorage -> Activado
    if ((Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue).$reg1Name -ne 3) {
        New-ItemProperty -Path $reg1Path -Name $reg1Name -Value 3 -Type DWord -Force | Out-Null
        Write-Host "DirectStorage: Activado" -ForegroundColor Green
		$script:changesMade = $true
    }

    # 2. MPO -> Desactivado
    $mpoValue = (Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue).$reg2Name
    if ($mpoValue -ne 5) {
        New-ItemProperty -Path $reg2Path -Name $reg2Name -Value 5 -Type DWord -Force | Out-Null
        Write-Host "MPO: Desactivado" -ForegroundColor Green
		$script:changesMade = $true
    }

    # 3. Modo Energia -> Maximo rendimiento
    $null = Set-MaximoRendimiento

    # 4. Test Hz Mouse
    $null = Test-MousePollingRate

    # 5. Mouse Acceleration -> OFF
    $currentAccel = Get-MouseAccelStatus
    if ($currentAccel.Estado -eq "Activado") {
        Toggle-MouseAcceleration  # Desactiva si está ON
        Write-Host "Mouse Acceleration: DESACTIVADA (Gaming Mode)" -ForegroundColor Green
    }

	# 6. AMD Shader Cache -> Siempre Activado + limpiar
	Log-Progress "Aplicando Shader Cache AMD..." Yellow

	# === REFRESCAR GPUs SIEMPRE ===
	$gpus = Get-AllAMDGPUs
	if ($gpus.Count -eq 0) {
		Log-Progress "No se detectó AMD RX → saltando Shader Cache" Gray
	} else {
		# === FORZAR CREACIÓN DE UMD SI NO EXISTE ===
		foreach ($gpu in $gpus) {
			if (-not (Test-Path $gpu.UMD)) {
				New-Item -Path $gpu.UMD -Force | Out-Null
				Log-Progress "Creada clave UMD: $($gpu.UMD)" DarkGray
			}
		}

		# === LEER VALOR ACTUAL ===
		$currentValue = $null
		try {
			$currentValue = (Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue).$reg3Name
		} catch {}

		$currentByte = if ($currentValue) { $currentValue[0] } else { 0x31 }
		$isAlwaysOn = $currentByte -eq 0x32

		if (-not $isAlwaysOn) {
			# === APLICAR 32 00 ===
			$applied = Apply-ShaderCacheToAll -Value @([byte]0x32, [byte]0x00)
			Log-Progress "Shader Cache: Siempre Activado (32 00) en $applied GPU(s)" Green
			Log-Progress "Limpiando caché AMD..." Yellow
			Clear-GPUCache -Vendor "AMD"
		} else {
			Log-Progress "Shader Cache: YA en Siempre Activado" Green
		}
	}
	
	# === 7. NVIDIA: Shader Cache -> 10GB ===
	if ($script:hasNVIDIA) {
		Write-Host "Comprobando Shader Cache NVIDIA..." -ForegroundColor Yellow
		if (Set-NVIDIAShaderCache -SizeName "10GB") {
			Write-Host "Limpiando cache NVIDIA..." -ForegroundColor Yellow
			Clear-GPUCache -Vendor "NVIDIA"
		}
	}
			
	# === 8. MEMORIA VIRTUAL: COMPLETAR A $Global:TargetRAM (SOLO SI ES NECESARIO) ===
	$physicalRAM = Get-PhysicalRAM
	if ($physicalRAM -lt ($Global:TargetRAM / 1GB)) {
		Write-Host "`nConfigurando memoria virtual para alcanzar $($Global:TargetRAM / 1GB)GB..." -ForegroundColor Yellow
		Configure-CustomPagefile -Silent
	} else {
		Write-Host "RAM suficiente ($([int]$physicalRAM) GB). No se necesita pagefile." -ForegroundColor Gray
	}
	
	# === REFRESCAR ESTADO ===
    Update-Status
    Write-Host "`nCONFIGURACION AUTOMATICA COMPLETADA" -ForegroundColor Cyan
	
    Start-Sleep -Seconds 2
}

# === ACTUALIZAR ESTADO ===
function Update-Status {
    $script:estado1 = "Desactivado"; $script:valor1 = "No existe"
    $value1 = Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue
    if ($value1) { $script:valor1 = $value1.$reg1Name; if ($value1.$reg1Name -eq 3) { $script:estado1 = "Activado" } }

    $script:estado2 = "Activado"; $script:valor2 = "No existe"
    $value2 = Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue
    if ($value2) { $script:valor2 = $value2.$reg2Name; if ($value2.$reg2Name -eq 5) { $script:estado2 = "Desactivado" } }

    # === NUEVO: DETECCIÓN DE AMD RX CON GPU-Z ===
    $hasAMDRX = $false
    $amdGPUName = $null
    if ($script:gpuzInfo) {
        foreach ($info in $script:gpuzInfo) {
            if ($info.Line -match "AMD Radeon RX [56789]") {
                $hasAMDRX = $true
                $amdGPUName = $info.Line
                break
            }
        }
    }

    # === INTENTAR CON REGISTRO CLÁSICO ===
    $gpus = Get-AllAMDGPUs
    $script:estado3 = "No detectado"; $script:valor3 = "No existe"

    if ($gpus.Count -gt 0) {
        try {
            if (-not (Test-Path $gpus[0].UMD)) { New-Item -Path $gpus[0].UMD -Force | Out-Null }
            $value3 = Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue
            if ($value3 -and $value3.$reg3Name) {
                $script:valor3 = "{0:X2} 00" -f $value3.$reg3Name[0]
                if ($value3.$reg3Name[0] -eq 0x32) { $script:estado3 = "Siempre Activado" }
                elseif ($value3.$reg3Name[0] -eq 0x31) { $script:estado3 = "AMD Optimizado" }
                else { $script:estado3 = "Valor: $($script:valor3)" }
            } else {
                $script:estado3 = "AMD Optimizado"
            }
        } catch { $script:estado3 = "AMD Optimizado" }
    }
    # === FALLBACK: SI NO HAY REGISTRO, PERO GPU-Z VE AMD RX ===
    elseif ($hasAMDRX) {
        # Intentar buscar en TODAS las claves de display
        $baseKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
        $subkeys = Get-ChildItem $baseKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d+$" }
        foreach ($key in $subkeys) {
            $driverDesc = Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue
            if ($driverDesc -and $driverDesc.DriverDesc -match "AMD Radeon RX [56789]") {
                $umdPath = "$($key.PSPath)\UMD"
                if (-not (Test-Path $umdPath)) { New-Item -Path $umdPath -Force | Out-Null }
                $value3 = Get-ItemProperty -Path $umdPath -Name $reg3Name -ErrorAction SilentlyContinue
                if ($value3 -and $value3.$reg3Name) {
                    $script:valor3 = "{0:X2} 00" -f $value3.$reg3Name[0]
                    if ($value3.$reg3Name[0] -eq 0x32) { $script:estado3 = "Siempre Activado" }
                    elseif ($value3.$reg3Name[0] -eq 0x31) { $script:estado3 = "AMD Optimizado" }
                    else { $script:estado3 = "Valor: $($script:valor3)" }
                } else {
                    $script:estado3 = "AMD Optimizado"
                }
                $gpus = @([PSCustomObject]@{ UMD = $umdPath })
                break
            }
        }
    }

	# === MODO ENERGÍA - DETECCIÓN FIABLE ===
	$script:estado4 = "No existe"
	$script:valor4 = "Maximo rendimiento"

	$plans = Get-PowerPlans
	$activeOutput = powercfg -getactivescheme | Out-String
	$activeGuid = $null
	if ($activeOutput -match '([a-f0-9-]{36})') { $activeGuid = $matches[1] }

	$performanceNames = @("Maximo rendimiento", "Ultimate Performance", "Alto rendimiento", "High performance")

	$found = $false
	foreach ($plan in $plans) {
		$cleanName = $plan.Name -replace '[^\x00-\x7F]', 'a'
		foreach ($name in $performanceNames) {
			if ($cleanName -match ([regex]::Escape($name) -replace '[^\x00-\x7F]', 'a')) {
				if ($plan.Guid -eq $activeGuid) {
					$script:estado4 = "Activado"
				} else {
					$script:estado4 = "Desactivado (existe)"
				}
				$found = $true
				break
			}
		}
		if ($found) { break }
	}

    # === MOUSE POLLING RATE ===
    if ($script:mouseTested -and $script:mouseHz) {
        $script:mouseEstado = "$($script:mouseHz)Hz"
    } else {
        $script:mouseEstado = "Test no realizado"
    }
	
		# === MOUSE ACCELERATION ===
	$mouseAccel = Get-MouseAccelStatus
	$script:mouseAccelEstado = $mouseAccel.Estado
	$script:mouseAccelColor = $mouseAccel.Color
	
	# === NVIDIA SHADER CACHE ===
	if ($script:hasNVIDIA) {
		Read-NVIDIAShaderCache  # ← AÑADE ESTO PARA LEER SIEMPRE
		if ($script:nvidiaShaderCache -and $script:nvidiaShaderCache -is [PSCustomObject]) {
			$script:estado7 = if ($script:nvidiaShaderCache.Hex -eq "0x00002800") { "10GB" } else { $script:nvidiaShaderCache.Text }
			$script:valor7 = $script:nvidiaShaderCache.Hex
		} else {
			$script:estado7 = "No detectado"
			$script:valor7 = "N/A"
		}
	}
	
    # === ESPACIO EN DISCO ===
    Get-DiskSpaceInfo

    # === ESTADO MEMORIA VIRTUAL – LECTURA FIABLE DEL REGISTRO ===
    $physicalRAM = Get-PhysicalRAM
    $ramGB = [int]$physicalRAM
    $targetGB = $Global:TargetRAM / 1GB

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    $pagingProp = Get-ItemProperty $regPath -Name "PagingFiles" -ErrorAction SilentlyContinue

    $currentPagefileGB = 0
    $driveLetter = "Ninguna"

    if ($pagingProp -and $pagingProp.PagingFiles) {
        # Forzar como array y limpiar
        $lines = @($pagingProp.PagingFiles) | Where-Object { $_ }
        foreach ($line in $lines) {
            if ($line -match "^([A-Z]:\\pagefile\.sys)\s+(\d+)\s+(\d+)") {
                $driveLetter = ($matches[1] -split ":")[0] + ":"
                $maxMB = [int]$matches[3]
                $currentPagefileGB = [math]::Round($maxMB / 1024, 1)
                break  # Solo la primera entrada activa
            }
        }
    }

    $totalVirtualRAM = $ramGB + $currentPagefileGB

    if ($ramGB -ge $targetGB) {
        $script:pagefileState = "$ramGB GB RAM (suficiente)"
        $script:pagefileColor = "Green"
    }
    elseif ($currentPagefileGB -gt 0) {
        $script:pagefileState = "Configurado en $driveLetter (Actualmente: $totalVirtualRAM GB - Objetivo: $targetGB GB)"
        $color = if ($totalVirtualRAM -ge $targetGB) { "Green" } 
                 elseif ($totalVirtualRAM -ge ($targetGB * 0.8)) { "Yellow" } 
                 else { "Red" }
        $script:pagefileColor = $color
    }
    else {
        $needed = $targetGB - $ramGB
        $script:pagefileState = "$ramGB GB RAM (falta $needed GB)"
        $script:pagefileColor = "Red"
    }

}

# === DETECCIÓN DINÁMICA DE OPCIONES DE MENÚ ===
function Get-DynamicMenuOptions {
    $options = @()

	# === 1. DirectStorage ===
	$options += @{
		Number = $options.Count + 1
		Key = "1"
		Text = "Alternar DirectStorage"
		Action = {
			$current = (Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue).$reg1Name
			if ($current -ne 3) {
				New-ItemProperty -Path $reg1Path -Name $reg1Name -Value 3 -Type DWord -Force | Out-Null
				Write-Host "`nDirectStorage: Activado (3)" -ForegroundColor Green
			} else {
				Set-ItemProperty -Path $reg1Path -Name $reg1Name -Value 0 -Type DWord -Force | Out-Null
				Write-Host "`nDirectStorage: Desactivado (0)" -ForegroundColor Yellow
			}
			$script:changesMade = $true
			Start-Sleep -Milliseconds 800
		}
	}

	# === 2. MPO ===
	$options += @{
		Number = $options.Count + 1
		Key = "2"
		Text = "Alternar MPO"
		Action = {
			$current = (Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue).$reg2Name
			if ($current -ne 5) {
				New-ItemProperty -Path $reg2Path -Name $reg2Name -Value 5 -Type DWord -Force | Out-Null
				Write-Host "`nMPO: Desactivado (5)" -ForegroundColor Green
			} else {
				Remove-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue
				Write-Host "`nMPO: Activado (eliminado)" -ForegroundColor Yellow
			}
			$script:changesMade = $true
			Start-Sleep -Milliseconds 800
		}
	}

    # 3. Modo Energía
    $options += @{
        Number = $options.Count + 1
        Key = "3"
        Text = "Activar Modo de Energia: Maximo rendimiento"
        Action = { 
            $success = Set-MaximoRendimiento
            Start-Sleep -Seconds 1
        }
    }

    # 4. Test Hz Mouse
    $options += @{
        Number = $options.Count + 1
        Key = "4"
        Text = "Test Hz Mouse"
        Action = { 
            $null = Test-MousePollingRate
            Start-Sleep -Milliseconds 800
        }
    }

    # 5. Aceleración Mouse
    $options += @{
        Number = $options.Count + 1
        Key = "5"
        Text = "Alternar Aceleracion Mouse"
        Action = { 
            Toggle-MouseAcceleration
            Start-Sleep -Milliseconds 800
        }
    }

    # === AMD SHADER CACHE (solo si hay AMD RX) ===
    if ($script:hasAMD) {
        $options += @{
            Number = $options.Count + 1
            Key    = [string]($options.Count + 1)
            Text   = "AMD: Alternar Shader Cache"
            Action = {
                # --- CÓDIGO SEGURO SIN param ---
                $localGpus = Get-AllAMDGPUs
                if ($localGpus.Count -eq 0) {
                    Write-Host "`nNo se detectó ninguna GPU AMD RX" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    return
                }

                # Leer valor actual
                $currentValue = $null
                try {
                    $currentValue = (Get-ItemProperty -Path $localGpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue).$reg3Name
                } catch { }

                $currentByte = if ($currentValue) { $currentValue[0] } else { 0x31 }

                if ($currentByte -eq 0x32) {
                    # Cambiar a 31 00 (AMD Optimizado)
                    $applied = 0
                    foreach ($gpu in $localGpus) {
                        if ($gpu.Name -notmatch "RX [56789]") { continue }
                        try {
                            if (-not (Test-Path $gpu.UMD)) { New-Item -Path $gpu.UMD -Force | Out-Null }
                            Set-ItemProperty -Path $gpu.UMD -Name $reg3Name -Value @([byte]0x31, [byte]0x00) -Type Binary -Force | Out-Null
                            $applied++
                        } catch {
                            Log-Progress "ERROR Shader Cache [$($gpu.Name)]: $($_.Exception.Message)" Red
                        }
                    }
                    Write-Host "`nShader Cache: AMD Optimizado (31 00) en $applied GPU(s)" -ForegroundColor Yellow
                } else {
                    # Cambiar a 32 00 (Siempre Activado)
                    $applied = 0
                    foreach ($gpu in $localGpus) {
                        if ($gpu.Name -notmatch "RX [56789]") { continue }
                        try {
                            if (-not (Test-Path $gpu.UMD)) { New-Item -Path $gpu.UMD -Force | Out-Null }
                            Set-ItemProperty -Path $gpu.UMD -Name $reg3Name -Value @([byte]0x32, [byte]0x00) -Type Binary -Force | Out-Null
                            $applied++
                        } catch {
                            Log-Progress "ERROR Shader Cache [$($gpu.Name)]: $($_.Exception.Message)" Red
                        }
                    }
                    Write-Host "`nShader Cache: Siempre Activado (32 00) en $applied GPU(s)" -ForegroundColor Green
                    Write-Host "Limpiando cache AMD..." -ForegroundColor Yellow
                    Clear-GPUCache -Vendor "AMD"
                }
                $script:changesMade = $true
                Start-Sleep -Milliseconds 800
            }
        }
    }

    # === NVIDIA SHADER CACHE (solo si hay NVIDIA y se leyó) ===
	if ($script:hasNVIDIA -and $script:nvidiaShaderCache -and $script:nvidiaShaderCache -is [PSCustomObject]) {
		$options += @{
			Number = $options.Count + 1
			Key = [string]($options.Count + 1)
			Text = "NVIDIA: Reducir/Aumentar Shader Cache"
			Action = {
				$sizes = @("Off","128MB","256MB","512MB","1GB","4GB","5GB","8GB","10GB","100GB","Unlimited")
				Write-Host "`nSelecciona cantidad de Shader Cache:" -ForegroundColor Cyan
				for ($i = 0; $i -lt $sizes.Count; $i++) {
					$name = $sizes[$i]
					$color = if ($name -eq "Unlimited" -or ($name -match "GB" -and [int]($name -replace "GB","") -ge 10)) { "Green" } else { "Red" }
					Write-Host " $($i+1) - $name" -ForegroundColor $color
				}
				Write-Host " S - Salir" -ForegroundColor Gray

				do { $choice = (Read-Host "`nElige 1-$($sizes.Count) o S").ToUpper() }
				while ($choice -notin 1..$sizes.Count -and $choice -ne "S")

				if ($choice -eq "S") { return }

				$selected = $sizes[$choice - 1]
				if (Set-NVIDIAShaderCache -SizeName $selected) {
					Write-Host "Limpiando cache NVIDIA..." -ForegroundColor Yellow
					Clear-GPUCache -Vendor "NVIDIA"
					Start-Sleep -Seconds 1
					Read-NVIDIAShaderCache  # ← Solo lee, sin logs
				}
			}
		}
	}
	
    # === MEMORIA VIRTUAL DINAMICA (solo si RAM < TargetRAM) ===
    $physicalRAM = Get-PhysicalRAM
    if ($physicalRAM -lt ($Global:TargetRAM / 1GB)) {
        $options += @{
            Number = $options.Count + 1
            Key = [string]($options.Count + 1)
            Text = "Memoria Virtual: Completar a $($Global:TargetRAM / 1GB)GB"
            Action = {
                Configure-CustomPagefile
            }
        }
    }

	# === REFRESCAR MENU ===
    $options += @{
        Number = $options.Count + 1
        Key = "R"
        Text = "Refrescar menu / Actualizar estado"
        Action = {
            Write-Host "`nRefrescando estado del sistema..." -ForegroundColor Cyan
            Update-Status
            Start-Sleep -Milliseconds 800
        }
    }

    # Opción Salir (siempre al final)
    $options += @{
        Number = $options.Count + 1
        Key = "S"
        Text = "Salir"
        Action = { $script:exitMenu = $true }
    }

    return $options
}

# === MOSTRAR MENU ===
function Show-Menu {
    # === 1. PRIMERO: GENERAR LAS OPCIONES DINÁMICAS ===
    $script:menuOptions = Get-DynamicMenuOptions

    # === 2. ACTUALIZAR ESTADO (necesario para colores y textos) ===
    Update-Status

    # === 3. LIMPIAR PANTALLA ===
    Clear-Host

    # === CABECERA ===
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " OPTIMIZADOR " -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # === OPCIONES PRINCIPALES (FIJAS) ===
    $color1 = if ($script:estado1 -eq "Activado") { "Green" } else { "Red" }
    Write-Host "1. DirectStorage -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado1" -NoNewline -ForegroundColor $color1
    Write-Host " (Recomendado Activado)" -ForegroundColor Yellow
    Write-Host " DirectStorage es una tecnologia de Microsoft que mejora los tiempos de carga de los juegos al permitir que la tarjeta grafica acceda directamente a los datos del SSD / Puede causar inestabilidad o crasheos en Vulkan" -ForegroundColor Gray
    Write-Host ""

    $color2 = if ($script:estado2 -eq "Desactivado") { "Green" } else { "Red" }
    Write-Host "2. Multi-Plane Overlay (MPO) -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado2" -NoNewline -ForegroundColor $color2
    Write-Host " (Recomendado Desactivado)" -ForegroundColor Yellow
    Write-Host " Multi-Plane Overlay, una caracteristica de renderizado grafico que busca optimizar el rendimiento. Desactivarlo evita parpadeos y stuttering / +Carga CPU" -ForegroundColor Gray
    Write-Host ""

    $color4 = if ($script:estado4 -eq "Activado") { "Green" } else { "Red" }
    Write-Host "3. Modo energia: Maximo rendimiento -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado4" -NoNewline -ForegroundColor $color4
    Write-Host " (Recomendado Activado)" -ForegroundColor Yellow
    Write-Host " Modo de maximo rendimiento para gaming" -ForegroundColor Gray
    Write-Host ""

    $mouseColor = if ($script:mouseTested -and $script:mouseHz -lt 1000) { "Green" } elseif ($script:mouseTested) { "Red" } else { "White" }
    Write-Host "4. Hz Mouse -> " -NoNewline -ForegroundColor White
    Write-Host "$script:mouseEstado" -NoNewline -ForegroundColor $mouseColor
    Write-Host " (Recomendado menos de 1000Hz)" -ForegroundColor Yellow
    Write-Host " Para evitar problemas de stuttering en algunos juegos se recomiendan menos de 1000Hz. No confundir con DPI. Configuralo en la aplicacion de tu mouse." -ForegroundColor Gray
    Write-Host ""

    Write-Host "5. Aceleracion Mouse -> " -NoNewline -ForegroundColor White
    Write-Host "$script:mouseAccelEstado" -NoNewline -ForegroundColor $script:mouseAccelColor
    Write-Host " (Recomendado Desactivado)" -ForegroundColor Yellow
    Write-Host " Desactiva la aceleracion de Windows para AIM consistente en shooters (CS2, Valorant, CoD)" -ForegroundColor Gray
    Write-Host " + Muscle memory real | + Headshots precisos" -ForegroundColor Cyan
    Write-Host ""

    # === AMD SHADER CACHE (solo si está en menuOptions) ===
    $amdOption = $script:menuOptions | Where-Object { $_.Text -match "AMD: Alternar Shader Cache" }
    if ($amdOption) {
        $color3 = if ($script:estado3 -eq "Siempre Activado") { "Green" } else { "Red" }
        Write-Host "$($amdOption.Number). AMD: Shader Cache -> " -NoNewline -ForegroundColor White
        Write-Host "$script:estado3" -NoNewline -ForegroundColor $color3
        Write-Host " (Recomendado Siempre Activado)" -ForegroundColor Yellow
        Write-Host " Mejora FPS en juegos (solo AMD RX): pool de cache ilimitado. AMD Optimizado = mas micro-cortes" -ForegroundColor Gray
        Write-Host " Posible stuttering al principio al tener que generarse Shaders nuevos" -ForegroundColor Gray
        Write-Host ""
    }

	# === NVIDIA SHADER CACHE ===
	$nvidiaOption = $script:menuOptions | Where-Object { $_.Text -match "NVIDIA: Reducir/Aumentar Shader Cache" }
	if ($nvidiaOption -and $script:nvidiaShaderCache -and $script:nvidiaShaderCache -is [PSCustomObject]) {
		$color = $script:nvidiaShaderCache.Color
		Write-Host "$($nvidiaOption.Number). NVIDIA: Shader Cache -> " -NoNewline -ForegroundColor White
		Write-Host "$($script:nvidiaShaderCache.Text)" -NoNewline -ForegroundColor $color
		Write-Host " (Recomendado: 10GB)" -ForegroundColor Yellow
		Write-Host " Aumenta la cache de shaders para reducir stuttering en juegos" -ForegroundColor Gray
		Write-Host " 10GB = ideal para 8GB+ VRAM | Usa menos en GPUs con poca VRAM" -ForegroundColor Gray
		Write-Host ""
	}

    # === INFO HARDWARE ===
    Write-Host "INFO Placa Base:" -ForegroundColor Cyan
    Write-Host " $script:motherboard" -ForegroundColor White
    Write-Host ""

    Write-Host "INFO GPU (GPU-Z):" -ForegroundColor Cyan
    if ($script:gpuzInfo) {
        foreach ($info in $script:gpuzInfo) {
            if ($info.Line.Trim() -ne "") {
                Write-Host " $($info.Line)" -ForegroundColor $info.Color
            }
        }
    }
    Show-RebarWarning
    Write-Host ""

    Write-Host "INFO RAM (CPU-Z):" -ForegroundColor Cyan
    if ($script:cpuzInfo) {
        Write-Host " $($script:cpuzInfo.Line)" -ForegroundColor $script:cpuzInfo.Color
    }
    Show-XmpWarning
    Write-Host ""

    # === ESPACIO EN DISCO (solo sistema) ===
    Write-Host "ESPACIO DE DISCO EN EL SISTEMA OPERATIVO" -ForegroundColor Cyan
    if ($script:systemDisk) {
        $freePercent = $script:systemDisk.PercentFree
        $color = if ($freePercent -lt 20) { "Red" } elseif ($freePercent -lt 30) { "Yellow" } else { "Green" }
        Write-Host " $($script:systemDisk.Drive): - " -NoNewline -ForegroundColor White
        Write-Host "$freePercent% libre" -ForegroundColor $color
        if ($freePercent -lt 20) {
            Write-Host "ADVERTENCIA: Espacio critico. Libera espacio urgentemente." -ForegroundColor Red
            Write-Host "Usa TreeSize Free: https://www.jam-software.com/treesize_free" -ForegroundColor Yellow
        }
    } else {
        Write-Host " No se pudo detectar el disco del sistema." -ForegroundColor Red
    }
    Write-Host ""
	
	Write-Host "MEMORIA VIRTUAL" -ForegroundColor Cyan
    Write-Host "Configuracion actual -> " -NoNewline -ForegroundColor White
    Write-Host "$script:pagefileState" -ForegroundColor $script:pagefileColor
    Write-Host " Util para sistemas con menos de 32GB de RAM" -ForegroundColor Gray
    Write-Host ""

    Write-Host "$script:backupInfo" -ForegroundColor Cyan
    Write-Host ""

    # === LISTADO DE OPCIONES DISPONIBLES ===
    Write-Host "Opciones:" -ForegroundColor Green
    foreach ($opt in $script:menuOptions) {
        if ($opt.Key -eq "S") {
            Write-Host " $($opt.Key) - $($opt.Text)" -ForegroundColor Red
        } elseif ($opt.Key -eq "R") {
            Write-Host " $($opt.Key) - $($opt.Text)" -ForegroundColor Cyan   # ← resaltada para que se vea útil
        } else {
            Write-Host " $($opt.Key) - $($opt.Text)" -ForegroundColor White
        }
    }
    Write-Host ""
}

# === MENÚ FINAL INTELIGENTE: SOLO PREGUNTA SI HUBO CAMBIOS ===
function Show-FinalMenu {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " OPTIMIZADOR FINALIZADO " -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    if ($script:changesMade) {
        Write-Host "SE HAN REALIZADO CAMBIOS" -ForegroundColor Red
        Write-Host ""
        Write-Host "REINICIA EL ORDENADOR PARA APLICAR TODOS LOS CAMBIOS" -ForegroundColor Green
        Write-Host ""
        Write-Host "R - Reiniciar ahora" -ForegroundColor Green
        Write-Host "S - Salir sin reiniciar" -ForegroundColor Gray
        Write-Host ""

        do {
            $final = (Read-Host "Elige opcion").ToUpper()
        } while ($final -notin "R", "S")

        # Restaurar zoom antes de salir/reiniciar
        Restore-ConsoleZoom

        if ($final -eq "R") {
            Write-Host "Reiniciando el sistema en 5 segundos..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        } else {
            Write-Host "Saliendo sin reiniciar. Hasta la proxima!" -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
    }
    else {
        Write-Host "No se realizaron cambios." -ForegroundColor Yellow
        Write-Host ""
        Restore-ConsoleZoom
    }
}

# === VARIABLES ===
$Global:TargetRAM = 32GB
$script:pagefileBackupDone = $false
$script:changesMade = $false
$script:gpus = $null
$script:hasAMD = $false
$script:hasNVIDIA = $false
$script:exitMenu = $false
$script:mouseHz = $null
$script:mouseTested = $false

# === INICIO ===
Set-ConsoleZoomAndMaximize
Clear-Host
RegistersBackup
Update-BatchFile
Update-CPUZInfo
Update-GPUZInfo
GPU-CheckGPUZorRegister
Initialize-NVIDIAInspector
Show-LoadingProcess
Clear-Host

# === PREGUNTA AL USUARIO ===
Write-Host "`nAntes de empezar cierra cualquier juego y al finalizar reinicia el ordenador para aplicar los cambios" -ForegroundColor Yellow
Write-Host "`nElige como ejecutar el script:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Automatico" -ForegroundColor White
Write-Host "2. Manual" -ForegroundColor White
Write-Host ""

do {
    $modo = Read-Host "Elige 1 o 2"
} while ($modo -notin "1", "2")

if ($modo -eq "1") {
    Start-AutoMode
}

# === INICIO DIRECTO AL MENÚ SIN REFRESCO ===
$script:exitMenu = $false
do {
    Show-Menu
    $opcion = (Read-Host "Elige opcion").ToUpper()
    $selected = $script:menuOptions | Where-Object { $_.Key -eq $opcion }
    if ($selected) {
        if ($selected.Action) {
            & $selected.Action
        }
        if ($script:exitMenu) { break }
    } else {
        Write-Host "`nOpcion invalida" -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
} while ($true)

# === LLAMADA AL MENÚ FINAL ===
Show-FinalMenu
