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
        $process = Start-Process -FilePath $exePath -ArgumentList "-txt=meminfo.txt" -WorkingDirectory $scriptPath -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $script:cpuzInfo = "CPU-Z tardo demasiado"
            $script:motherboard = "No disponible"
            Log-Progress "ERROR: CPU-Z tardo demasiado" Red -Error
            return
        }

        # === ESPERAR ARCHIVO ===
        $txtReady = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path $txtPath) -and (Test-Path "$txtPath.txt")) {
                Rename-Item "$txtPath.txt" "meminfo.txt" -Force
            }
            if ((Test-Path $txtPath) -and (Get-Item $txtPath).Length -gt 500) {
                $txtReady = $true
                break
            }
        }
        if (-not $txtReady) {
            $script:cpuzInfo = "No se genero meminfo.txt"
            $script:motherboard = "No disponible"
            Log-Progress "ERROR: No se genero meminfo.txt" Red -Error
            return
        }

        # === LEER TODO Y LIMPIAR ACENTOS ===
        $rawText = Get-Content $txtPath -Raw -Encoding Default
        $lines = $rawText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        $lines = $lines -replace '[^\x00-\x7F]', 'a' # QUITAR ACENTOS

        # === DEBUG DMI LIMPIO ===
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
            Log-Progress "# ERROR: No se encontro DMI Baseboard" Red -Error -Subsection
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

        # === CONSEJO XMP ===
        $script:xmpAdvice = $null
        if ($xmpStatus.Split(';')[0] -eq "Desactivado" -and $maxXMP -gt 0 -and $motherboardModel -ne "Desconocido") {
            $cleanName = $motherboardModel -replace '\s*\([^)]*\)', '' -replace '\s+$', ''
            $script:xmpAdvice = "Mejoras de hasta un 20% en FPS. Para activar XMP busca en Google -> $cleanName enable XMP site:youtube.com"
        }

        $line = "RAM | XMP-$maxXMP | Actual: $currentSpeed MHz (x2 = $effectiveSpeed) -> $($xmpStatus.Split(';')[0])"
        $script:cpuzInfo = [PSCustomObject]@{ Line = $line; Color = $xmpStatus.Split(';')[1] }

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
            Log-Progress "Descargando GPU-Z..." Yellow
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 30
                if (-not (Test-Path $zipPath)) { throw "ZIP no se descargo." }
                Log-Progress "Extrayendo GPU-Z..." Yellow
                $tempExtract = "$scriptPath\gpuz_extract"
                if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
                Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force
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
		if ($process) {
			$null = $process.WaitForExit(15000)
			if (-not $process.HasExited) {
				$process.Kill()
				$process.WaitForExit()
			}
		}
        Log-Progress "# GENERANDO GPUZ.XML" Yellow -Subsection
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $script:gpuzInfo = "GPU-Z tardo demasiado y fue detenido"
            Log-Progress "$script:gpuzInfo" Red -Error
            return
        }

        # === ESPERAR XML ===
        Log-Progress "# LEYENDO GPUZ.XML" Yellow -Subsection
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
            Log-Progress "$script:gpuzInfo" Red -Error
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

                # === CORRECCIÓN: Contar SOLO dGPUs ===
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
        $script:gpuzInfo = "Error GPU-Z: $($_.Exception.Message)"
        Log-Progress "$script:gpuzInfo" Red -Error
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
	$form.TopMost = $true
	$form.Add_Shown({ $form.Activate(); $timer.Start() })
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

# === INICIO ===
Clear-Host
Update-CPUZInfo
Update-GPUZInfo

# === ESPERAR A QUE GPU-Z TERMINE Y LIBERE EL ARCHIVO ===
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
    if (-not (Get-Process gpuz -ErrorAction SilentlyContinue) -and (Test-Path "$PSScriptRoot\gpuz.xml")) {
        break
    }
    Start-Sleep -Seconds 1
    $waited++
}
if ($waited -ge $maxWait) {
    Write-Host "ADVERTENCIA: GPU-Z no termino. Forzando cierre..." -ForegroundColor Yellow
    taskkill /F /IM gpuz.exe /T | Out-Null
    Start-Sleep -Seconds 1
}

Show-LoadingProcess
Clear-Host

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

