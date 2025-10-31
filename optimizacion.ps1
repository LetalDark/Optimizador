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
        try {
            if (-not (Test-Path $gpu.UMD)) {
                New-Item -Path $gpu.UMD -Force | Out-Null
            }
            Set-ItemProperty -Path $gpu.UMD -Name $reg3Name -Value $Value -Type Binary -Force | Out-Null
            $applied++
        } catch {
            Log-Progress "ERROR Shader Cache [$($gpu.Name)]: $($_.Exception.Message)" Red
        }
    }
    return $applied
}

# === LIMPIEZA DE CACHE AMD ===
function Clear-AMDCache {
    $cacheBackupPath = "$script:backupPath\AMD_Cache_Backup"
    New-Item -Path $cacheBackupPath -ItemType Directory -Force | Out-Null

    $users = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notmatch "Public|Default" }
    $totalCopied = 0

    foreach ($user in $users) {
        $amdPath = "$($user.FullName)\AppData\Local\AMD"
        if (Test-Path $amdPath) {
            $cacheFolders = Get-ChildItem $amdPath -Directory | Where-Object { $_.Name -match "cache" -and $_.Name -notmatch "Backup" }
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
        Write-Host "`nCache AMD: $totalCopied carpetas respaldadas y eliminadas" -ForegroundColor Green
        Write-Host "   Backup: $cacheBackupPath" -ForegroundColor DarkGray
    } else {
        Write-Host "`nNo se encontro cache AMD" -ForegroundColor Yellow
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

# === GENERAR Y LEER TXT DE CPU-Z (XMP + RAM + PLACA BASE) ===
function Update-CPUZInfo {
    try {
        $scriptPath = $PSScriptRoot
        if (-not $scriptPath) { $scriptPath = (Get-Location).Path }
        $zipUrl = "https://download.cpuid.com/cpu-z/cpu-z_2.17-en.zip"
        $zipPath = "$scriptPath\cpuz.zip"
        $exePath = "$scriptPath\cpuz_x64.exe"
        $txtPath = "$scriptPath\meminfo.txt"

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
		$maxWait = 45  # Aumentado a 45 segundos para PCs viejos
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
						Log-Progress "# RENOMBRANDO: $possibleFile -> meminfo.txt" Yellow -Subsection
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

        # === CONSEJO XMP ===
        $script:xmpAdvice = $null
        if ($statusText -eq "Desactivado" -and $maxXMP -gt 0 -and $motherboardModel -ne "Desconocido") {
            $cleanName = $motherboardModel -replace '\s*\([^)]*\)', '' -replace '\s+$', ''
            $script:xmpAdvice = "Mejoras de hasta un 20% en FPS. Para activar XMP busca en Google -> $cleanName enable XMP site:youtube.com"
        }

        $line = "RAM | XMP-$maxXMP | Actual: $currentSpeed MHz (x2 = $effectiveSpeed) -> $statusText"
        $script:cpuzInfo = [PSCustomObject]@{ Line = $line; Color = $statusColor }

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

# === GENERAR Y LEER XML DE GPU-Z ===
function Update-GPUZInfo {
    try {
        $scriptPath = $PSScriptRoot
        if (-not $scriptPath) { $scriptPath = (Get-Location).Path }
        $gpuzPath = "$scriptPath\gpuz.exe"
        $xmlPath = "$scriptPath\gpuz.xml"
        $zipUrl = "https://ftp.nluug.nl/pub/games/PC/guru3d/generic/GPU-Z-[Guru3D.com].zip"
        $zipPath = "$scriptPath\gpuz_temp.zip"

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

            # === CONSEJO REBAR (solo para menú) ===
            $script:rebarAdvice = $null
            $rebarOff = $script:gpuzInfo | Where-Object { $_.Line -match "ReBAR: Desactivado" }
            if ($rebarOff) {
                if ($script:motherboard -and $script:motherboard -ne "Desconocido" -and $script:motherboard -ne "No disponible") {
                    $cleanName = $script:motherboard -replace '\s*\([^)]*\)', '' -replace '\s+$', ''
                    $script:rebarAdvice = "Mejoras de hasta un 15% en FPS. Para activar Resizable Bar busca en Google -> $cleanName enable Resizable Bar site:youtube.com"
                } else {
                    $script:rebarAdvice = "Mejoras de hasta un 15% en FPS. Para activar Resizable Bar busca en Google -> enable Resizable Bar site:youtube.com"
                }
            }

            # === FINAL GPU-Z ===
            Log-Progress "# ----------------------------------------------------" Gray -Subsection
            Log-Progress "# GPU-Z: INFORMACION LEIDA CORRECTAMENTE" Green -Subsection
            Log-Progress "# ----------------------------------------------------" Gray -Subsection

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

# === GESTIONAR MODO MAXIMO RENDIMIENTO (CON LIMPIEZA DE DUPLICADOS) ===
function Set-MaximoRendimiento {
    Write-Host "Procesando plan de maximo rendimiento..." -ForegroundColor Yellow

    # === NOMBRES EN DIFERENTES IDIOMAS ===
    $performanceNames = @(
        "Maximo rendimiento",    # Español
        "Ultimate Performance",  # Inglés
        "Alto rendimiento",      # Español alternativo
        "High performance"       # Inglés alternativo
    )

    # === OBTENER PLANES ACTUALES ===
    $plansRaw = powercfg -l | Out-String
    $plans = $plansRaw.Trim()
    
    # === DETECTAR PLAN ACTIVO ACTUAL ===
    $activePlanLine = $plans -split "`n" | Where-Object { $_ -match '\*' } | Select-Object -First 1
    $activePlanGuid = $null
    if ($activePlanLine -match '([a-f0-9-]{36})') {
        $activePlanGuid = $matches[1]
    }
    
    # === BUSCAR PLANES DE RENDIMIENTO EXISTENTES ===
    $performancePlans = @()
    
    foreach ($name in $performanceNames) {
        # Buscar sin importar acentos
        $cleanName = $name.ToLower() -replace '[áéíóú]', ''
        
        $matchingLines = $plans -split "`n" | Where-Object { 
            $cleanLine = $_.ToLower() -replace '[áéíóú]', ''
            $cleanLine -match [regex]::Escape($cleanName)
        }
        
        foreach ($line in $matchingLines) {
            if ($line -match '([a-f0-9-]{36})') {
                $performancePlans += [PSCustomObject]@{
                    Guid = $matches[1]
                    Name = $line.Trim()
                    IsActive = ($matches[1] -eq $activePlanGuid)
                }
            }
        }
    }

    # === ELIMINAR DUPLICADOS Y MANTENER SOLO UNO ===
    $uniquePlans = $performancePlans | Sort-Object Guid -Unique

    # === SI EXISTE ALGÚN PLAN DE RENDIMIENTO ===
    if ($uniquePlans.Count -gt 0) {
        $targetPlan = $uniquePlans[0]
        Write-Host "Plan encontrado: $($targetPlan.Name)" -ForegroundColor Green
        
        # Activar si no está activo
        if (-not $targetPlan.IsActive) {
            $result = powercfg /s $targetPlan.Guid 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Plan de maximo rendimiento activado." -ForegroundColor Green
                return $true
            } else {
                Write-Host "Error al activar plan existente." -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "Plan de maximo rendimiento ya esta activo." -ForegroundColor Yellow
            return $true
        }
    }

    # === SI NO EXISTE, INTENTAR CREAR ===
    Write-Host "Creando nuevo plan de maximo rendimiento..." -ForegroundColor Yellow
    
    # Intentar crear Ultimate Performance
    $result = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Plan creado exitosamente." -ForegroundColor Green
        
        # Buscar y activar el plan recién creado
        Start-Sleep -Seconds 2
        $newPlansRaw = powercfg -l | Out-String
        
        foreach ($name in $performanceNames) {
            $cleanName = $name.ToLower() -replace '[áéíóú]', ''
            
            $matchingLine = $newPlansRaw -split "`n" | Where-Object { 
                $cleanLine = $_.ToLower() -replace '[áéíóú]', ''
                $cleanLine -match [regex]::Escape($cleanName)
            } | Select-Object -First 1
            
            if ($matchingLine -and $matchingLine -match '([a-f0-9-]{36})') {
                $result = powercfg /s $matches[1] 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Plan de maximo rendimiento activado." -ForegroundColor Green
                    return $true
                }
            }
        }
        
        Write-Host "Plan creado pero no se pudo activar automaticamente." -ForegroundColor Yellow
        return $false
    } else {
        Write-Host "No se pudo crear el plan (sistema puede no soportarlo)." -ForegroundColor Yellow
        return $false
    }
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
	$mouseMoveHandler = {
		$mouseTimes.Add($sw.Elapsed.TotalMilliseconds)
		$script:mouseMoveCount++
		$sw.Restart()
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

# === ACTUALIZAR ESTADO ===
function Update-Status {
    $script:estado1 = "Desactivado"; $script:valor1 = "No existe"
    $value1 = Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue
    if ($value1) { $script:valor1 = $value1.$reg1Name; if ($value1.$reg1Name -eq 3) { $script:estado1 = "Activado" } }

    $script:estado2 = "Activado"; $script:valor2 = "No existe"
    $value2 = Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue
    if ($value2) { $script:valor2 = $value2.$reg2Name; if ($value2.$reg2Name -eq 5) { $script:estado2 = "Desactivado" } }

	$script:estado3 = "AMD Optimizado"; $script:valor3 = "No existe"
		$gpus = Get-AllAMDGPUs
		if ($gpus.Count -gt 0) {
			# --- CREAR UMD SI NO EXISTE (FIX CRÍTICO) ---
			if (-not (Test-Path $gpus[0].UMD)) {
				New-Item -Path $gpus[0].UMD -Force | Out-Null
			}
			$value3 = Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue
			if ($value3 -and $value3.$reg3Name) {
				$script:valor3 = "{0:X2} 00" -f $value3.$reg3Name[0]
				if ($value3.$reg3Name[0] -eq 0x32) { $script:estado3 = "Siempre Activado" }
			}
		}
		
	# === MODO ENERGÍA - DETECCIÓN FIABLE (MULTI-IDIOMA) ===
	$script:estado4 = "No existe"
	$script:valor4 = "Maximo rendimiento"

	# Ejecutar powercfg -l dos veces para forzar refresco
	$null = powercfg -l | Out-Null
	Start-Sleep -Milliseconds 300
	$plansRaw = powercfg -l | Out-String
	$plans = ([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($plansRaw.Trim()))) -replace '[^\x00-\x7F]', 'a'

	# Nombres en diferentes idiomas
	$performanceNames = @("Maximo rendimiento", "Ultimate Performance", "Alto rendimiento", "High performance", "Rendimiento elevado")

	$maximoLine = $null
	foreach ($name in $performanceNames) {
		$maximoLine = $plans -split "`n" | Where-Object { $_ -match $name } | Select-Object -First 1
		if ($maximoLine) { break }
	}

	if ($maximoLine) {
		$hasAsterisk = $maximoLine -match '\*$'
		$guidMatch = [regex]::Match($maximoLine, '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})')
		if ($guidMatch.Success) {
			$currentMatch = powercfg -getactivescheme | Select-String -Pattern '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})'
			$currentGuid = if ($currentMatch) { $currentMatch.Matches[0].Groups[1].Value } else { $null }
			if ($currentGuid -eq $guidMatch.Groups[1].Value) {
				$script:estado4 = "Activado"
			} else {
				$script:estado4 = "Desactivado (existe)"
			}
		} elseif ($hasAsterisk) {
			$script:estado4 = "Activado"
		} else {
			$script:estado4 = "Desactivado (existe)"
		}
	}
	
	# === NUEVO: MOUSE POLLING RATE ===
	if ($script:mouseTested -and $script:mouseHz) {
		$script:mouseEstado = "$($script:mouseHz)Hz"
	} else {
		$script:mouseEstado = "Test no realizado"
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
    Write-Host "`n# ===================================================================" -ForegroundColor Cyan
    Write-Host "# INICIANDO OPTIMIZADOR DE RENDIMIENTO" -ForegroundColor White
    Write-Host "# ===================================================================`n" -ForegroundColor Cyan

	if ($script:gpuzInfo -and $script:gpuzInfo.Count -gt 0 -and $script:gpuzInfo[0].Line) {
		Write-Host "# GPUs DETECTADAS (GPU-Z)" -ForegroundColor Green
		Write-Host "# -------------------------------------------------------------------" -ForegroundColor Green
		foreach ($info in $script:gpuzInfo) {
			if ($info.Line -and $info.Line.Trim() -ne "" -and $info.Line -notmatch "ReBAR:|Conexion actual:") {
				if ($info.Line -match "^(AMD|NVIDIA|Intel|GeForce|Radeon|Arc)") {
					Write-Host "# $($info.Line.Trim())" -ForegroundColor White
				}
			}
		}
		Write-Host "# -------------------------------------------------------------------`n" -ForegroundColor Green
	} else {
		Write-Host "# GPU-Z: No se pudo leer informacion" -ForegroundColor Red
	}

    Write-Host "# CARGA COMPLETADA" -ForegroundColor Cyan
    Write-Host "# ===================================================================`n" -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# === MODO AUTOMÁTICO / MANUAL ===
function Start-AutoMode {
    Write-Host "`nMODO AUTOMATICO: Aplicando configuracion recomendada..." -ForegroundColor Cyan
    $global:changesMade = $true

    # 1. DirectStorage -> Activado
    if ((Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue).$reg1Name -ne 3) {
        New-ItemProperty -Path $reg1Path -Name $reg1Name -Value 3 -Type DWord -Force | Out-Null
        Write-Host "DirectStorage: Activado" -ForegroundColor Green
    }

    # 2. MPO -> Desactivado
    $mpoValue = (Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue).$reg2Name
    if ($mpoValue -ne 5) {
        New-ItemProperty -Path $reg2Path -Name $reg2Name -Value 5 -Type DWord -Force | Out-Null
        Write-Host "MPO: Desactivado" -ForegroundColor Green
    }

    # 3. Modo Energia -> Maximo rendimiento
    $null = Set-MaximoRendimiento

    # 4. Test Hz Mouse
    $null = Test-MousePollingRate

    # 5. AMD Shader Cache -> Siempre Activado + limpiar
    $gpus = Get-AllAMDGPUs
    if ($gpus.Count -gt 0) {
        $currentValue = (Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue).$reg3Name
        $current = if ($currentValue -and $currentValue[0] -eq 0x32) { 0x32 } else { 0x31 }
        if ($current -ne 0x32) {
            $applied = Apply-ShaderCacheToAll -Value @([byte]0x32, [byte]0x00)
            Write-Host "Shader Cache: Siempre Activado en $applied claves" -ForegroundColor Green
            Write-Host "Limpiando cache AMD..." -ForegroundColor Yellow
            Clear-AMDCache
        }
    }

    Write-Host "`nCONFIGURACION AUTOMATICA COMPLETADA" -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# === MOSTRAR MENU (AMD ULTIMA, OPCIONAL) ===
function Show-Menu {
    Update-Status
    $gpus = Get-AllAMDGPUs
    $hasAMD = $gpus.Count -gt 0

    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " OPTIMIZADOR " -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # === 1. DirectStorage ===
    $rec1 = "Activado"
    $color1 = if ($script:estado1 -eq $rec1) { "Green" } else { "Red" }
    Write-Host "1. DirectStorage -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado1" -NoNewline -ForegroundColor $color1
    Write-Host " (Recomendado $rec1)" -ForegroundColor Yellow
    Write-Host " DirectStorage es una tecnologia de Microsoft que mejora los tiempos de carga de los juegos al permitir que la tarjeta grafica acceda directamente a los datos del SSD / Puede causar inestabilidad o crasheos en Vulkan" -ForegroundColor Gray
    #Write-Host " Ruta: $reg1Path" -ForegroundColor DarkGray
    #Write-Host " Valor: $reg1Name = $script:valor1" -ForegroundColor DarkGray
    Write-Host ""

    # === 2. MPO ===
    $rec2 = "Desactivado"
    $color2 = if ($script:estado2 -eq $rec2) { "Green" } else { "Red" }
    Write-Host "2. Multi-Plane Overlay (MPO) -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado2" -NoNewline -ForegroundColor $color2
    Write-Host " (Recomendado $rec2)" -ForegroundColor Yellow
    Write-Host " Multi-Plane Overlay, una caracteristica de renderizado grafico que busca optimizar el rendimiento. Desactivarlo evita parpadeos y stuttering / +Carga CPU" -ForegroundColor Gray
    #Write-Host " Ruta: $reg2Path" -ForegroundColor DarkGray
    #Write-Host " Valor: $reg2Name = $script:valor2" -ForegroundColor DarkGray
    Write-Host ""

    # === 3. Modo Energía (siempre visible) ===
    $rec4 = "Activado"
    $color4 = if ($script:estado4 -eq "Activado") { "Green" } else { "Red" }
    Write-Host "3. Modo energia: Maximo rendimiento -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado4" -NoNewline -ForegroundColor $color4
    Write-Host " (Recomendado $rec4)" -ForegroundColor Yellow
    Write-Host " Modo de maximo rendimiento para gaming" -ForegroundColor Gray
    Write-Host ""

	# === NUEVA OPCIÓN 4: MOUSE POLLING RATE ===
	$recMouse = "menos de 1000Hz"
	$mouseColor = "White"
	if ($script:mouseTested -and $script:mouseHz) {
		if ($script:mouseHz -lt 1000) { 
			$mouseColor = "Green" 
		} else { 
			$mouseColor = "Red" 
		}
	}
	Write-Host "4. Hz Mouse -> " -NoNewline -ForegroundColor White
	Write-Host "$script:mouseEstado" -NoNewline -ForegroundColor $mouseColor
	Write-Host " (Recomendado $recMouse)" -ForegroundColor Yellow
	Write-Host " Para evitar problemas de stuttering en algunos juegos se recomiendan menos de 1000Hz. No confundir con DPI. Configuralo en la aplicacion de tu mouse." -ForegroundColor Gray
	Write-Host ""

    # === 4. AMD Shader Cache (solo si hay AMD RX) ===
    if ($hasAMD) {
        $rec3 = "Siempre Activado"
        $color3 = if ($script:estado3 -eq $rec3) { "Green" } else { "Red" }
        Write-Host "5. AMD: Shader Cache -> " -NoNewline -ForegroundColor White
        Write-Host "$script:estado3" -NoNewline -ForegroundColor $color3
        Write-Host " (Recomendado $rec3)" -ForegroundColor Yellow
        Write-Host " Mejora FPS en juegos (solo AMD RX): pool de cache ilimitado. AMD Optimizado = mas micro-cortes" -ForegroundColor Gray
		Write-Host " Posible stuttering al principio al tener que generarse Shaders nuevos" -ForegroundColor Gray
        #Write-Host " Ruta: $reg3Base" -ForegroundColor DarkGray
        #Write-Host " Valor: $reg3Name = $script:valor3" -ForegroundColor DarkGray
        Write-Host ""
    }

    Write-Host ""
    Write-Host "INFO Placa Base:" -ForegroundColor Cyan
    Write-Host " $script:motherboard" -ForegroundColor White
    Write-Host ""

    Write-Host "INFO GPU (GPU-Z):" -ForegroundColor Cyan
    if ($script:gpuzInfo -and $script:gpuzInfo.Count -gt 0) {
        foreach ($info in $script:gpuzInfo) {
            $safeColor = if ($info.Color -and $info.Color -match '^(Green|Red|Yellow|White|Cyan)$') { $info.Color } else { 'White' }
            Write-Host " $($info.Line)" -ForegroundColor $safeColor
        }
        if ($script:rebarAdvice) {
            Write-Host " $script:rebarAdvice" -ForegroundColor Yellow
        }
    } else {
        Write-Host " $($script:gpuzInfo)" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "INFO RAM (CPU-Z):" -ForegroundColor Cyan
    if ($script:cpuzInfo) {
        $ramColor = if ($script:cpuzInfo.Color -and $script:cpuzInfo.Color -match '^(Green|Red|Yellow|White|Cyan)$') { $script:cpuzInfo.Color } else { 'White' }
        Write-Host " $($script:cpuzInfo.Line)" -ForegroundColor $ramColor
        if ($script:xmpAdvice) {
            Write-Host " $script:xmpAdvice" -ForegroundColor Yellow
        }
    } else {
        Write-Host " $($script:cpuzInfo)" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host ""
    Write-Host "$script:backupInfo" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Opciones:" -ForegroundColor Green
    Write-Host " 1 - Alternar DirectStorage"
    Write-Host " 2 - Alternar MPO"
    Write-Host " 3 - Activar Modo de Energia: Maximo rendimiento"
    Write-Host " 4 - Test Hz Mouse"	
    if ($hasAMD) { Write-Host " 5 - AMD: Alternar Shader Cache" }
    Write-Host " S - Salir"
    Write-Host ""
}

# === VARIABLES ===
$changesMade = $false
$script:mouseHz = $null
$script:mouseTested = $false

# === INICIO ===
Clear-Host
RegistersBackup
Update-BatchFile
Update-CPUZInfo
Update-GPUZInfo
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

# === CONTINUAR AL MENÚ ===
Show-Menu

# === BUCLE ===
do {
    $opcion = Read-Host "Elige opcion"
    $gpus = Get-AllAMDGPUs
    $hasAMD = $gpus.Count -gt 0

    switch ($opcion.ToUpper()) {
        "1" {
            $current = (Get-ItemProperty -Path $reg1Path -Name $reg1Name -ErrorAction SilentlyContinue).$reg1Name
            if ($current -ne 3) {
                New-ItemProperty -Path $reg1Path -Name $reg1Name -Value 3 -Type DWord -Force | Out-Null
                Write-Host "`nSSD/NVMe: Activado (3)" -ForegroundColor Green
                $changesMade = $true
            } else {
                Set-ItemProperty -Path $reg1Path -Name $reg1Name -Value 0 -Type DWord
                Write-Host "`nSSD/NVMe: Desactivado (0)" -ForegroundColor Yellow
                $changesMade = $true
            }
            Start-Sleep -Milliseconds 800
            Show-Menu
        }
        "2" {
            $current = (Get-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue).$reg2Name
            if ($current -ne 5) {
                New-ItemProperty -Path $reg2Path -Name $reg2Name -Value 5 -Type DWord -Force | Out-Null
                Write-Host "`nMPO: Desactivado (5)" -ForegroundColor Green
                $changesMade = $true
            } else {
                Remove-ItemProperty -Path $reg2Path -Name $reg2Name -ErrorAction SilentlyContinue
                Write-Host "`nMPO: Activado (eliminado)" -ForegroundColor Yellow
                $changesMade = $true
            }
            Start-Sleep -Milliseconds 800
            Show-Menu
        }
        "3" {
            $success = Set-MaximoRendimiento
            if ($success) { $changesMade = $true }
            Start-Sleep -Seconds 1
            Show-Menu
        }
		"4" {
			$null = Test-MousePollingRate  # Añadir $null = para ocultar el retorno
			Start-Sleep -Milliseconds 800
			Show-Menu
		}
        "5" {
            if (-not $hasAMD) {
                Write-Host "`nOpcion no valida (no hay GPU AMD)" -ForegroundColor Red
                Start-Sleep -Seconds 1
                Show-Menu
                continue
            }
            $currentValue = $null
            try { $currentValue = (Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue).$reg3Name } catch { }
            $current = if ($currentValue -and $currentValue[0] -eq 0x32) { 0x32 } else { 0x31 }
           
            if ($current -eq 0x32) {
                $applied = Apply-ShaderCacheToAll -Value @([byte]0x31, [byte]0x00)
                Write-Host "`nShader Cache: AMD Optimizado (31 00) en $applied claves" -ForegroundColor Yellow
                $changesMade = $true
            } else {
                $applied = Apply-ShaderCacheToAll -Value @([byte]0x32, [byte]0x00)
                Write-Host "`nShader Cache: Siempre Activado (32 00) en $applied claves" -ForegroundColor Green
                Write-Host "Limpiando cache AMD..." -ForegroundColor Yellow
                Clear-AMDCache
                $changesMade = $true
            }
            Start-Sleep -Milliseconds 800
            Show-Menu
        }
        "S" {
            Clear-Host
            Write-Host "Saliendo..." -ForegroundColor Cyan
            if ($changesMade) {
                Write-Host ""
                Write-Host "Se han realizado cambios" -ForegroundColor Yellow
                Write-Host "Reinicio recomendado." -ForegroundColor White
                Write-Host ""
                Write-Host "[R] Reiniciar ahora" -ForegroundColor Green
                Write-Host "[S] Salir sin reiniciar" -ForegroundColor Gray
                $final = Read-Host "Opcion"
                if ($final.ToUpper() -eq "R") {
                    Write-Host "Reiniciando..." -ForegroundColor Cyan
                    Start-Sleep -Seconds 2
                    Restart-Computer -Force
                }
            }
            Write-Host "Backup: $backupPath" -ForegroundColor Cyan
            Start-Sleep -Seconds 2
            exit
        }
        default {
            Write-Host "`nOpcion invalida" -ForegroundColor Red
            Start-Sleep -Seconds 1
            Show-Menu
        }
    }
} while ($opcion.ToUpper() -ne "S")

