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

# === RUTAS DE REGISTRO ===
$reg1Path = "HKLM:\SYSTEM\CurrentControlSet\Services\EhStorClass\Parameters"
$reg1Name = "StorageSupportedFeatures"

$reg2Path = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
$reg2Name = "OverlayTestMode"

$reg3Base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
$reg3Name = "ShaderCache"

# === BACKUP ===
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

$script:backupInfo = if ($backupFiles.Count -eq 3) { "Backup OK: $backupPath" } else { "Backup PARCIAL: $backupPath" }

# === DETECTAR SOLO AMD RADEON RX ===
function Get-AllAMDGPUs {
    $amdGPUs = @()
    $keys = Get-ChildItem $reg3Base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d+$" }
    foreach ($key in $keys) {
        try {
            $driverDesc = Get-ItemProperty -Path $key.PSPath -Name "DriverDesc" -ErrorAction SilentlyContinue
            $umdPath = "$($key.PSPath)\UMD"
            if ($driverDesc -and $driverDesc.DriverDesc -match "^AMD Radeon RX [6789]" -and (Test-Path $umdPath)) {
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
            Set-ItemProperty -Path $gpu.UMD -Name $reg3Name -Value $Value -Type Binary -Force | Out-Null
            $applied++
        } catch { }
    }
    return $applied
}

# === LIMPIEZA DE CACHE AMD ===
function Clear-AMDCache {
    $cacheBackupPath = "$backupPath\AMD_Cache_Backup"
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

# === GENERAR Y LEER XML DE GPU-Z (SIN ACENTOS) ===
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
            Write-Host "Descargando GPU-Z (ZIP)..." -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30
                if (-not (Test-Path $zipPath)) { throw "ZIP no se descargo." }

                Write-Host "Extrayendo GPU-Z..." -ForegroundColor Yellow
                $tempExtract = "$scriptPath\gpuz_extract"
                if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
                Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force

                $exeFile = Get-ChildItem -Path $tempExtract -Filter "GPU-Z.*.exe" -Recurse | Select-Object -First 1
                if (-not $exeFile) { throw "No se encontro GPU-Z.*.exe en el ZIP" }

                Move-Item $exeFile.FullName $gpuzPath -Force
                Remove-Item $tempExtract -Recurse -Force
                Remove-Item $zipPath -Force

                Write-Host "GPU-Z descargado y extraido correctamente." -ForegroundColor Green
            }
            catch {
                $script:gpuzInfo = "Error al descargar/extraer GPU-Z: $($_.Exception.Message)"
                Write-Host "ERROR: $script:gpuzInfo" -ForegroundColor Red
                return
            }
        }

        # === EJECUTAR GPU-Z ===
        Write-Host "Ejecutando GPU-Z..." -ForegroundColor Yellow
        if (Test-Path $xmlPath) { Remove-Item $xmlPath -Force }
        $process = Start-Process -FilePath $gpuzPath -ArgumentList "-dump `"$xmlPath`"" -PassThru -WindowStyle Hidden

        Write-Host "Generando gpuz.xml..." -ForegroundColor Yellow
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $script:gpuzInfo = "GPU-Z tardo demasiado y fue detenido"
            Write-Host "ERROR: $script:gpuzInfo" -ForegroundColor Red
            return
        }

        # === ESPERAR XML ===
        Write-Host "Leyendo gpuz.xml..." -ForegroundColor Yellow
        $xmlReady = $false
        for ($i = 0; $i -lt 10; $i++) {
            if (Test-Path $xmlPath) {
                try {
                    [xml]$test = Get-Content $xmlPath -Raw -ErrorAction Stop
                    if ($test.gpuz_dump -and $test.gpuz_dump.card) {
                        $xmlReady = $true
                        break
                    }
                } catch { }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $xmlReady) {
            $script:gpuzInfo = "GPU-Z no genero un XML valido"
            Write-Host "ERROR: $script:gpuzInfo" -ForegroundColor Red
            return
        }

		# === LEER XML ===
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
				
				# Línea 3: Conexión PCIe
				$maxMatch = [regex]::Match($card.businterface, "x(\d+)\s+([\d\.]+)")
				$recWidth = if ($maxMatch.Success) { "x$($maxMatch.Groups[1].Value)" } else { "x?" }
				$recGenRaw = if ($maxMatch.Success) { [double]$maxMatch.Groups[2].Value } else { 0 }
				$recGen = if ($recGenRaw -gt 0) { "Gen$([math]::Floor($recGenRaw))" } else { "Gen?" }
				
				$curMatch = [regex]::Match($card.businterface, "@\s*x(\d+)\s+([\d\.]+)")
				$curWidth = if ($curMatch.Success) { "x$($curMatch.Groups[1].Value)" } else { "x?" }
				$curGenRaw = if ($curMatch.Success) { [double]$maxMatch.Groups[2].Value } else { 0 }
				$curGen = if ($curGenRaw -gt 0) { "Gen$([math]::Floor($curGenRaw))" } else { "Gen?" }
				
				if (-not $curMatch.Success -and $card.pcie_current -match "Gen\s*([\d\.]+)") {
					$curGen = "Gen$([math]::Floor([double]$matches[1]))"
				}
				
				$optima = "PCIe $recWidth $recGen"
				$actual = "PCIe $curWidth $curGen"
				
				# Verificar si la conexión es correcta para múltiples GPUs
				$currentWidth = ($curWidth -replace 'x','' -as [int])
				$optimalWidth = ($recWidth -replace 'x','' -as [int])
				$currentGen = $curGenRaw
				$optimalGen = $recGenRaw

				# Si hay múltiples GPUs, x8 es normal cuando la óptima es x16
				$totalCards = $cards.Count
				$isMultiGPU = $totalCards -gt 1

				# Calcular ancho de banda relativo (considerando generación)
				$genMultipliers = @{"1.0"=1; "2.0"=2; "3.0"=4; "4.0"=8; "5.0"=16}
				$currentMultiplier = if ($genMultipliers.ContainsKey("$currentGen")) { $genMultipliers["$currentGen"] } else { 1 }
				$optimalMultiplier = if ($genMultipliers.ContainsKey("$optimalGen")) { $genMultipliers["$optimalGen"] } else { 1 }

				$currentBandwidth = $currentWidth * $currentMultiplier
				$optimalBandwidth = $optimalWidth * $optimalMultiplier

				$widthOK = $currentWidth -eq $optimalWidth
				$genOK = $currentGen -eq $optimalGen
				$bandwidthOK = $currentBandwidth -ge ($optimalBandwidth * 0.5)  # Al menos 50% del ancho de banda óptimo

				if ($isMultiGPU -and $optimalWidth -eq 16 -and $currentWidth -eq 8 -and $genOK) {
					# Caso: Múltiples GPUs, misma generación, x8 cada una → Normal (Verde)
					$pcieColor = "Green"
				} elseif ($isMultiGPU -and $optimalWidth -eq 16 -and $currentWidth -eq 8 -and $currentGen -ge $optimalGen) {
					# Caso: Múltiples GPUs, generación igual o mejor, x8 cada una → Normal (Verde)
					$pcieColor = "Green"
				} elseif ($widthOK -and $genOK) {
					# Caso: Conexión idéntica a la óptima (Verde)
					$pcieColor = "Green"
				} elseif ($bandwidthOK -and $currentGen -ge $optimalGen) {
					# Caso: Ancho de banda suficiente y generación igual o mejor (Verde)
					$pcieColor = "Green"
				} else {
					# Caso: Conexión inferior (Rojo)
					$pcieColor = "Red"
				}

				# Añadir información de generación al texto si es relevante
				if (-not $genOK) {
					$actual += " [Gen$currentGen vs Gen$optimalGen]"
				}

				$script:gpuzInfo += [PSCustomObject]@{
					Line = "Conexion actual: $actual - Conexion optima: $optima"
					Color = $pcieColor
				}
			}
			
			# Línea vacía entre GPUs
			$script:gpuzInfo += [PSCustomObject]@{
				Line = ""
				Color = "White"
			}
		}

		# Remover la última línea vacía si existe
		if ($script:gpuzInfo.Count -gt 0 -and $script:gpuzInfo[-1].Line -eq "") {
			$script:gpuzInfo = $script:gpuzInfo[0..($script:gpuzInfo.Count-2)]
		}
		
		# === CONSEJO REBAR (MEJORADO) ===
		$script:rebarAdvice = $null
		$rebarOff = $script:gpuzInfo | Where-Object { $_.Line -match "ReBAR: Desactivado" }
		if ($rebarOff) {
			if ($script:motherboard -and $script:motherboard -ne "Desconocido" -and $script:motherboard -ne "No disponible") {
				# Limpiar el nombre: quitar contenido entre paréntesis y espacios extra
				$cleanName = $script:motherboard -replace '\s*\([^)]*\)', ''  # Quitar (MS-7c56)
				$cleanName = $cleanName.Trim()  # Quitar espacios sobrantes
				# Para búsqueda Google: reemplazar espacios por +
				$search = $cleanName -replace " ", "+"
				# Mostrar nombre limpio en el mensaje
				$script:rebarAdvice = "Para activar Resizable Bar busca en Google -> $cleanName enable Resizable Bar site:youtube.com"
			} else {
				$script:rebarAdvice = "Para activar Resizable Bar busca en Google -> enable Resizable Bar site:youtube.com"
			}
		}

        Write-Host "GPU-Z: Informacion leida correctamente." -ForegroundColor Green
    }
    catch {
        $script:gpuzInfo = "Error GPU-Z: $($_.Exception.Message)"
        Write-Host "ERROR GPU-Z: $($_.Exception.Message)" -ForegroundColor Red
    }
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
            Write-Host "Descargando CPU-Z..." -ForegroundColor Yellow
            try {
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile($zipUrl, $zipPath)
                Write-Host "Extrayendo CPU-Z..." -ForegroundColor Yellow
                $shell = New-Object -ComObject Shell.Application
                $zip = $shell.NameSpace($zipPath)
                foreach ($item in $zip.Items()) { $shell.NameSpace($scriptPath).CopyHere($item, 0x14) }
                Remove-Item $zipPath -Force
                Start-Sleep -Milliseconds 300
                if (-not (Test-Path $exePath)) { throw "No se encontro cpuz_x64.exe" }
                Write-Host "CPU-Z descargado y extraido correctamente." -ForegroundColor Green
            } catch {
                $script:cpuzInfo = "Error al descargar CPU-Z"
                $script:motherboard = "No disponible"
                $script:xmpAdvice = $null
                return
            }
        }

        # === EJECUTAR CPU-Z ===
        Write-Host "Ejecutando CPU-Z..." -ForegroundColor Yellow
        if (Test-Path $txtPath) { Remove-Item $txtPath -Force }
        $process = Start-Process -FilePath $exePath -ArgumentList "-txt=meminfo.txt" -WorkingDirectory $scriptPath -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit(15000)) { $process.Kill(); $script:cpuzInfo = "CPU-Z tardo demasiado"; return }

        # === ESPERAR ARCHIVO ===
        $txtReady = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path $txtPath) -and (Test-Path "$txtPath.txt")) { Rename-Item "$txtPath.txt" "meminfo.txt" -Force }
            if ((Test-Path $txtPath) -and (Get-Item $txtPath).Length -gt 500) { $txtReady = $true; break }
        }
        if (-not $txtReady) { $script:cpuzInfo = "No se genero meminfo.txt"; $script:motherboard = "No disponible"; return }

        # === LEER TODO Y LIMPIAR ACENTOS ===
        $rawText = Get-Content $txtPath -Raw -Encoding Default
        $lines = $rawText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        $lines = $lines -replace '[^\x00-\x7F]', 'a'  # QUITAR ACENTOS

        # === DEBUG: BUSCANDO DMI BASEBOARD ===
        Write-Host "`n=== BUSCANDO DMI BASEBOARD ===" -ForegroundColor Magenta
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq "DMI Baseboard") {
                Write-Host "DMI Baseboard encontrado en linea: $i" -ForegroundColor Green
                for ($j = $i; $j -lt [Math]::Min($i + 10, $lines.Count); $j++) {
                    Write-Host "  [$j] $($lines[$j])" -ForegroundColor DarkGray
                }
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Host "ERROR: No se encontro DMI Baseboard" -ForegroundColor Red
        }

        # === EXTRAER MODELO (2 LÍNEAS DESPUÉS, IGNORA ESPACIOS) ===
        $motherboardModel = "Desconocido"
        $baseboardIndex = [array]::IndexOf($lines, "DMI Baseboard")
        if ($baseboardIndex -ge 0) {
            $modelLineIndex = $baseboardIndex + 2
            if ($modelLineIndex -lt $lines.Count) {
                $modelLine = $lines[$modelLineIndex].Trim()
                if ($modelLine -match "^model\s+(.+)") {
                    $motherboardModel = $matches[1].Trim()
                    Write-Host "MODELO ENCONTRADO (linea $modelLineIndex): $motherboardModel" -ForegroundColor Yellow
                } else {
                    Write-Host "ERROR: No se encontro 'model' en linea $modelLineIndex - '$modelLine'" -ForegroundColor Red
                }
            }
        }

        $script:motherboard = $motherboardModel

        # === XMP + RAM ===
        $xmpProfiles = @()
        $currentSpeed = 0
        foreach ($line in $lines) {
            if ($line -match "XMP profile\s+XMP-(\d+)") { $xmpProfiles += [int]$matches[1] }
            if ($line -match "Clock Speed.*MHz.*\(Memory\)" -and $line -notmatch "\[0x") {
                if ($line -match "([\d\.]+)\s+MHz") { $currentSpeed = [double]$matches[1] }
            }
        }
        $maxXMP = if ($xmpProfiles.Count -gt 0) { ($xmpProfiles | Sort-Object -Descending)[0] } else { 0 }
        $effectiveSpeed = [math]::Round($currentSpeed * 2, 0)
        $xmpStatus = if ($maxXMP -gt 0 -and [math]::Abs($effectiveSpeed - $maxXMP) -le 80) { "Activado"; "Green" } else { "Desactivado"; "Red" }
        if ($maxXMP -eq 0) { $xmpStatus = "Sin XMP"; "Yellow" }

		# === CONSEJO XMP (MEJORADO) ===
		$script:xmpAdvice = $null
		if ($xmpStatus.Split(';')[0] -eq "Desactivado" -and $maxXMP -gt 0 -and $motherboardModel -ne "Desconocido") {
			# Limpiar el nombre: quitar contenido entre paréntesis y espacios extra
			$cleanName = $motherboardModel -replace '\s*\([^)]*\)', ''  # Quitar (MS-7c56)
			$cleanName = $cleanName.Trim()  # Quitar espacios sobrantes
			# Para búsqueda Google: reemplazar espacios por +
			$search = $cleanName -replace " ", "+"
			# Mostrar nombre limpio en el mensaje
			$script:xmpAdvice = "Para activar XMP busca en Google -> $cleanName enable XMP site:youtube.com"
		}

        $line = "RAM | XMP-$maxXMP | Actual: $currentSpeed MHz (x2 = $effectiveSpeed) -> $($xmpStatus.Split(';')[0])"
        $script:cpuzInfo = [PSCustomObject]@{ Line = $line; Color = $xmpStatus.Split(';')[1] }
		
        Write-Host "CPU-Z: Informacion leida correctamente." -ForegroundColor Green
    } catch {
        $script:cpuzInfo = "Error CPU-Z"
        $script:motherboard = "No disponible"
        $script:xmpAdvice = $null
    }
}

# === GESTIONAR MODO MAXIMO RENDIMIENTO ===
function Set-MaximoRendimiento {
    Write-Host "`nProcesando Maximo rendimiento..." -ForegroundColor Yellow

    # === LEER PLANES EN UTF-8 + LIMPIAR ACENTOS ===
    $plans = ([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes((powercfg -l | Out-String).Trim()))) -replace '[^\x00-\x7F]', 'a'

    # Buscar línea con "Maximo rendimiento"
    $maximoLine = $plans -split "`n" | Where-Object { $_ -match "Maximo rendimiento" } | Select-Object -First 1

    if ($maximoLine) {
        # Existe
        if ($maximoLine -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
            $guid = $matches[1]
        } else {
            Write-Host "Error: No se pudo extraer GUID." -ForegroundColor Red
            return $false
        }

        $isActive = $maximoLine -match '\*$'

        if ($isActive) {
            Write-Host "Maximo rendimiento ya esta activo." -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "Activando plan existente: $guid" -ForegroundColor Yellow
            $result = powercfg /s $guid
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Maximo rendimiento activado." -ForegroundColor Green
                return $true
            } else {
                Write-Host "Error al activar: $result" -ForegroundColor Red
                return $false
            }
        }
    } else {
        # No existe → crear
        Write-Host "Creando nuevo plan..." -ForegroundColor Yellow
        $result = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error al crear plan." -ForegroundColor Red
            return $false
        }

        # Recargar
        $plans = ([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes((powercfg -l | Out-String).Trim()))) -replace '[^\x00-\x7F]', 'a'
        $maximoLine = $plans -split "`n" | Where-Object { $_ -match "Maximo rendimiento" -and $_ -notmatch '\*' } | Select-Object -Last 1

        if ($maximoLine -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
            $guid = $matches[1]
            Write-Host "Plan creado: $guid" -ForegroundColor Green
            $result = powercfg /s $guid
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Maximo rendimiento activado." -ForegroundColor Green
                return $true
            } else {
                Write-Host "Error al activar nuevo plan." -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "Error: No se pudo obtener GUID del nuevo plan." -ForegroundColor Red
            return $false
        }
    }
}

# === TEST FRECUENCIA RATON ===
function Test-MousePollingRate {
    Write-Host "`nIniciando test de frecuencia de raton..." -ForegroundColor Yellow
    Write-Host "Mueve el raton en CIRCULOS rapidos durante 8 segundos" -ForegroundColor Cyan
    Write-Host "IMPORTANTE: Movimientos rapidos y constantes!" -ForegroundColor Red
    
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $times = New-Object System.Collections.Generic.List[double]
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "TEST RATON - Mueve en CIRCULOS RAPIDOS 8 segundos"
    $form.Width = 800
    $form.Height = 600
    $form.BackColor = [System.Drawing.Color]::LightBlue
    $form.FormBorderStyle = "FixedDialog"
    $form.StartPosition = "CenterScreen"
    
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "MOVIMIENTOS RAPIDOS EN CIRCULOS`n8 SEGUNDOS`nFrecuencia: Calculando..."
    $label.Size = New-Object System.Drawing.Size(580, 120)
    $label.Location = New-Object System.Drawing.Point(10, 10)
    $label.Font = New-Object System.Drawing.Font("Arial", 14, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::DarkBlue
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($label)
    
    $form.Add_MouseMove({
        $times.Add($sw.Elapsed.TotalMilliseconds)
        $sw.Restart()
    })
    
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 8000 # 8 segundos
    $timer.Add_Tick({
        $timer.Stop()
        $form.Close()
    })
    
    $form.Add_Shown({ $timer.Start() })
    [void]$form.ShowDialog()
    
    # Filtrar outliers y calcular mejor
    $validTimes = $times | Where-Object { $_ -gt 0 -and $_ -lt 20 } # Eliminar valores extremos
    if ($validTimes.Count -gt 10) {
        $avg = ($validTimes | Measure-Object -Average).Average
        $rate = [Math]::Round(1000 / $avg, 0)
        
        # Suavizado: tomar percentil 75 para evitar picos bajos
        $sortedTimes = $validTimes | Sort-Object
        $percentile75 = $sortedTimes[[Math]::Floor($sortedTimes.Count * 0.25)]
        $rateSmoothed = [Math]::Round(1000 / $percentile75, 0)
        
        $script:mouseHz = $rateSmoothed
        $script:mouseTested = $true
        
        Write-Host "Frecuencia de sondeo: $rateSmoothed Hz" -ForegroundColor Green
        Write-Host "Intervalo promedio: $([Math]::Round($avg, 2)) ms" -ForegroundColor DarkGray
        Write-Host "Muestras validas: $($validTimes.Count)" -ForegroundColor DarkGray
        
        # Diagnóstico
        if ($rateSmoothed -lt 450) {
            Write-Host "`nCONSEJO: Cierra apps en segundo plano y repite el test" -ForegroundColor Yellow
        }
        
        return $true
    } else {
        $script:mouseHz = $null
        $script:mouseTested = $false
        Write-Host "ERROR: Pocos movimientos detectados. Repite con movimientos mas rapidos." -ForegroundColor Red
        return $false
    }
}

$changesMade = $false
# === NUEVO: MOUSE POLLING RATE ===
$script:mouseHz = $null
$script:mouseTested = $false

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
        $value3 = Get-ItemProperty -Path $gpus[0].UMD -Name $reg3Name -ErrorAction SilentlyContinue
        if ($value3 -and $value3.$reg3Name) {
            $script:valor3 = "{0:X2} 00" -f $value3.$reg3Name[0]
            if ($value3.$reg3Name[0] -eq 0x32) { $script:estado3 = "Siempre Activado" }
        }
    }
	# === MODO ENERGÍA - DETECCIÓN FIABLE ===
	$script:estado4 = "No existe"
	$script:valor4 = "Maximo rendimiento"

	# Ejecutar powercfg -l dos veces para forzar refresco
	$null = powercfg -l | Out-Null
	Start-Sleep -Milliseconds 300
	$plansRaw = powercfg -l | Out-String
	$plans = ([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($plansRaw.Trim()))) -replace '[^\x00-\x7F]', 'a'

	$maximoLine = $plans -split "`n" | Where-Object { $_ -match "Maximo rendimiento" } | Select-Object -First 1

	if ($maximoLine) {
		$hasAsterisk = $maximoLine -match '\*$'
		$guidMatch = [regex]::Match($maximoLine, '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})')
		if ($guidMatch.Success) {
			$currentGuid = (powercfg -getactivescheme | Select-String -Pattern '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})').Matches[0].Groups[1].Value
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
    Write-Host " Ruta: $reg1Path" -ForegroundColor DarkGray
    Write-Host " Valor: $reg1Name = $script:valor1" -ForegroundColor DarkGray
    Write-Host ""

    # === 2. MPO ===
    $rec2 = "Desactivado"
    $color2 = if ($script:estado2 -eq $rec2) { "Green" } else { "Red" }
    Write-Host "2. Multi-Plane Overlay (MPO) -> " -NoNewline -ForegroundColor White
    Write-Host "$script:estado2" -NoNewline -ForegroundColor $color2
    Write-Host " (Recomendado $rec2)" -ForegroundColor Yellow
    Write-Host " Multi-Plane Overlay, una caracteristica de renderizado grafico que busca optimizar el rendimiento. Desactivarlo evita parpadeos y stuttering / +Carga CPU" -ForegroundColor Gray
    Write-Host " Ruta: $reg2Path" -ForegroundColor DarkGray
    Write-Host " Valor: $reg2Name = $script:valor2" -ForegroundColor DarkGray
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
	Write-Host " Para evitar problemas de stuttering en algunos juegos se recomiendan menos de 1000Hz" -ForegroundColor Gray
	Write-Host ""

    # === 4. AMD Shader Cache (solo si hay AMD RX) ===
    if ($hasAMD) {
        $rec3 = "Siempre Activado"
        $color3 = if ($script:estado3 -eq $rec3) { "Green" } else { "Red" }
        Write-Host "5. AMD: Shader Cache -> " -NoNewline -ForegroundColor White
        Write-Host "$script:estado3" -NoNewline -ForegroundColor $color3
        Write-Host " (Recomendado $rec3)" -ForegroundColor Yellow
        Write-Host " Mejora FPS en juegos (solo AMD RX): pool de cache ilimitado. AMD Optimizado = mas micro-cortes" -ForegroundColor Gray
        Write-Host " Ruta: $reg3Base" -ForegroundColor DarkGray
        Write-Host " Valor: $reg3Name = $script:valor3" -ForegroundColor DarkGray
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

# === INICIO ===
Clear-Host  # LIMPIA LA PANTALLA AL INICIAR
Update-CPUZInfo
Update-GPUZInfo
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
				Test-MousePollingRate
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

