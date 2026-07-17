#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot installer for PalworldOverlay (companion app + UE4SS bridge mod).

  Auto-recovers common failures: missing Node, download flakes, npm errors,
  Palworld path detection, UE4SS install, and locked mod folders.

.EXAMPLE
  .\install.ps1

.EXAMPLE
  .\install.ps1 -PalworldPath "D:\SteamLibrary\steamapps\common\Palworld" -Launch
#>
[CmdletBinding()]
param(
    [string] $PalworldPath = '',
    [switch] $SkipMaps,
    [switch] $SkipUe4ss,
    [switch] $SkipNpm,
    [switch] $SkipNodeInstall,
    [switch] $Launch,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$CompanionDir = Join-Path $RepoRoot 'companion'
$MapsDir = Join-Path $CompanionDir 'public\maps'
$BridgeSrc = Join-Path $RepoRoot 'bridge\PalworldAssistBridge'
$ModName = 'PalworldAssistBridge'
$MinNodeMajor = 20
$NodeMsiUrl = 'https://nodejs.org/dist/v22.17.0/node-v22.17.0-x64.msi'
$Ue4ssUrls = @(
    'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip',
    'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/zDEV-UE4SS_v3.0.1.zip'
)
# Primary + fallback hosts for map textures.
$MapFiles = @(
    @{
        Name = 'palworld-map.webp'
        Urls = @(
            'https://raw.githubusercontent.com/amantu-qbit/palworld-server-manager/main/public/palworld-map.webp',
            'https://cdn.jsdelivr.net/gh/amantu-qbit/palworld-server-manager@main/public/palworld-map.webp'
        )
        MinBytes = 100000
    },
    @{
        Name = 'palworld-treemap.webp'
        Urls = @(
            'https://raw.githubusercontent.com/amantu-qbit/palworld-server-manager/main/public/palworld-treemap.webp',
            'https://cdn.jsdelivr.net/gh/amantu-qbit/palworld-server-manager@main/public/palworld-treemap.webp'
        )
        MinBytes = 100000
    }
)

$script:InstallWarnings = [System.Collections.Generic.List[string]]::new()

function Write-Step([string] $Message) {
    if (-not $Quiet) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
}

function Write-Ok([string] $Message) {
    if (-not $Quiet) { Write-Host "    OK  $Message" -ForegroundColor Green }
}

function Write-WarnLine([string] $Message) {
    Write-Host "    !!  $Message" -ForegroundColor Yellow
}

function Write-ErrLine([string] $Message) {
    Write-Host "    ERR $Message" -ForegroundColor Red
}

function Add-InstallWarning([string] $Message) {
    [void] $script:InstallWarnings.Add($Message)
    Write-WarnLine $Message
}

function Read-YesNo([string] $Prompt, [bool] $Default = $true) {
    if ($Quiet) { return $Default }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^[yY]'
}

function Initialize-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = (
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
        )
    } catch {}
}

function Invoke-WithRetry {
    param(
        [scriptblock] $Action,
        [int] $Attempts = 3,
        [int] $DelaySeconds = 2,
        [string] $Label = 'operation'
    )
    $lastError = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return & $Action
        } catch {
            $lastError = $_
            if ($i -lt $Attempts) {
                Write-WarnLine "$Label failed (try $i/$Attempts): $($_.Exception.Message)"
                Start-Sleep -Seconds ($DelaySeconds * $i)
            }
        }
    }
    throw $lastError
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user) -join ';'

    foreach ($extra in @(
        'C:\Program Files\nodejs',
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
    )) {
        if ((Test-Path -LiteralPath $extra) -and ($env:Path -notlike "*$extra*")) {
            $env:Path = "$extra;$env:Path"
        }
    }
}

function Test-PalworldRunning {
    return [bool] (Get-Process -Name 'Palworld-Win64-Shipping', 'Palworld' -ErrorAction SilentlyContinue)
}

function Wait-ForPalworldClosed {
    if (-not (Test-PalworldRunning)) { return $true }
    Write-WarnLine 'Palworld is running — mod files may be locked.'
    if (-not (Read-YesNo 'Close Palworld now and continue? (recommended)' $true)) {
        return $false
    }
    Get-Process -Name 'Palworld-Win64-Shipping', 'Palworld' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 15; $i++) {
        if (-not (Test-PalworldRunning)) { return $true }
        Start-Sleep -Seconds 1
    }
    return -not (Test-PalworldRunning)
}

function Save-RemoteFile {
    param(
        [string[]] $Urls,
        [string] $Destination,
        [long] $MinBytes = 1,
        [int] $AttemptsPerUrl = 3
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $leaf = Split-Path -Leaf $Destination
    $errors = @()

    foreach ($url in $Urls) {
        $tmp = "$Destination.download"
        try {
            if (-not $Quiet) {
                Write-Host "    downloading $leaf ..."
            }
            Invoke-WithRetry -Label $leaf -Attempts $AttemptsPerUrl -DelaySeconds 2 -Action {
                if (Test-Path -LiteralPath $tmp) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
                if (-not (Test-Path -LiteralPath $tmp)) {
                    throw 'download produced no file'
                }
                $len = (Get-Item -LiteralPath $tmp).Length
                if ($len -lt $MinBytes) {
                    throw "file too small ($len bytes)"
                }
            }
            Move-Item -LiteralPath $tmp -Destination $Destination -Force
            return
        } catch {
            $errors += "$url → $($_.Exception.Message)"
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
            Write-WarnLine "download failed from mirror, trying next if available..."
        }
    }

    throw "Failed to download $leaf.`n    $($errors -join "`n    ")"
}

function Get-NodeMajorVersion {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    try {
        $versionText = & node -v 2>$null
    } catch {
        return $null
    }
    if ($versionText -match 'v?(\d+)') {
        return [int] $Matches[1]
    }
    return $null
}

function Test-NodeReady {
    Refresh-ProcessPath
    $major = Get-NodeMajorVersion
    if ($null -eq $major) { return $false }
    if ($major -lt $MinNodeMajor) { return $false }
    return [bool] (Get-Command npm -ErrorAction SilentlyContinue)
}

function Install-NodeViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }

    if (-not $Quiet) {
        Write-Host '    trying winget (OpenJS.NodeJS.LTS) ...'
    }
    & winget install --id OpenJS.NodeJS.LTS -e `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    Refresh-ProcessPath
    return (Test-NodeReady)
}

function Install-NodeViaMsi {
    $msi = Join-Path $env:TEMP ("PalworldOverlay-node-{0}.msi" -f [guid]::NewGuid().ToString('N'))
    try {
        Save-RemoteFile -Urls @($NodeMsiUrl) -Destination $msi -MinBytes 1000000
        if (-not $Quiet) {
            Write-Host '    running MSI installer (may prompt for admin) ...'
        }
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @(
            '/i', "`"$msi`"",
            '/qn',
            '/norestart',
            'ADDLOCAL=ALL'
        ) -Wait -PassThru

        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "msiexec failed with exit code $($proc.ExitCode). Right-click install.bat → Run as administrator."
        }

        Refresh-ProcessPath
        return (Test-NodeReady)
    } finally {
        if (Test-Path -LiteralPath $msi) {
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-NodeJs {
    Refresh-ProcessPath
    if (Test-NodeReady) {
        Write-Ok "Node.js $(& node -v)"
        return
    }

    $major = Get-NodeMajorVersion
    if ($null -ne $major -and $major -lt $MinNodeMajor) {
        Write-WarnLine "Node.js v$major found; need $MinNodeMajor+."
    } else {
        Write-WarnLine 'Node.js not found.'
    }

    if ($SkipNodeInstall) {
        throw "Node.js $MinNodeMajor+ is required. Install from https://nodejs.org/ or rerun without -SkipNodeInstall."
    }

    if (-not (Read-YesNo 'Install Node.js LTS (v22) automatically now?' $true)) {
        throw "Node.js $MinNodeMajor+ is required. Install from https://nodejs.org/ and rerun install.bat."
    }

    $installed = $false
    try { $installed = Install-NodeViaWinget } catch {
        Write-WarnLine "winget install failed: $($_.Exception.Message)"
    }
    if (-not $installed) {
        try { $installed = Install-NodeViaMsi } catch {
            throw "Automatic Node.js install failed: $($_.Exception.Message)"
        }
    }
    if (-not $installed) {
        throw 'Node.js installed but not on PATH. Close this window and rerun install.bat.'
    }
    Write-Ok "Installed Node.js $(& node -v)"
}

function Test-IsWin64Dir([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $exe = Join-Path $Path 'Palworld-Win64-Shipping.exe'
    $dll = Join-Path $Path 'UE4SS.dll'
    return (Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath $dll) -or
        ((Split-Path $Path -Leaf) -eq 'Win64')
}

function Resolve-Win64Path([string] $InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $null }
    $InputPath = $InputPath.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $InputPath)) { return $null }

    $path = (Resolve-Path -LiteralPath $InputPath).Path
    foreach ($candidate in @(
        $path,
        (Join-Path $path 'Pal\Binaries\Win64'),
        (Join-Path $path 'Binaries\Win64')
    )) {
        if (Test-IsWin64Dir $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-SteamLibraryPaths {
    $libraries = [System.Collections.Generic.List[string]]::new()
    $steamRoots = @()

    foreach ($regPath in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKCU:\Software\Valve\Steam'
    )) {
        try {
            $install = (Get-ItemProperty -Path $regPath -ErrorAction Stop).InstallPath
            if ($install) { $steamRoots += $install }
        } catch {}
    }

    foreach ($steamRoot in $steamRoots | Select-Object -Unique) {
        if (-not $libraries.Contains($steamRoot)) {
            [void] $libraries.Add($steamRoot)
        }
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        $content = Get-Content -LiteralPath $vdf -Raw
        foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
            $lib = $match.Groups[1].Value -replace '\\\\', '\'
            if (-not $libraries.Contains($lib)) {
                [void] $libraries.Add($lib)
            }
        }
    }
    return $libraries
}

function Find-PalworldWin64 {
    param([string] $Override)

    $fromOverride = Resolve-Win64Path -InputPath $Override
    if ($fromOverride) { return $fromOverride }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($lib in Get-SteamLibraryPaths) {
        [void] $candidates.Add((Join-Path $lib 'steamapps\common\Palworld\Pal\Binaries\Win64'))
    }
    foreach ($drive in @('C', 'D', 'E', 'F', 'G', 'H')) {
        foreach ($base in @(
            'SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64',
            'Program Files (x86)\Steam\steamapps\common\Palworld\Pal\Binaries\Win64',
            'Program Files\Steam\steamapps\common\Palworld\Pal\Binaries\Win64',
            'XboxGames\Palworld\Content\Pal\Binaries\Win64',
            'Games\Palworld\Pal\Binaries\Win64'
        )) {
            [void] $candidates.Add("${drive}:\$base")
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'Palworld-Win64-Shipping.exe')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Prompt-PalworldPath {
    param([string] $Initial)

    $win64 = Find-PalworldWin64 -Override $Initial
    if ($win64) { return $win64 }

    if ($Quiet) {
        throw 'Could not find Palworld. Pass -PalworldPath "C:\path\to\Palworld".'
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Write-WarnLine 'Could not auto-detect Palworld.'
        Write-Host '    Examples:' -ForegroundColor DarkGray
        Write-Host '      D:\SteamLibrary\steamapps\common\Palworld' -ForegroundColor DarkGray
        Write-Host '      D:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64' -ForegroundColor DarkGray
        $manual = Read-Host 'Palworld path (or leave blank to browse)'

        if ([string]::IsNullOrWhiteSpace($manual)) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                $dialog.Description = 'Select your Palworld folder (game root or Win64)'
                $dialog.ShowNewFolderButton = $false
                if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $manual = $dialog.SelectedPath
                }
            } catch {
                Write-WarnLine 'Folder browser unavailable — paste the path instead.'
                continue
            }
        }

        $win64 = Find-PalworldWin64 -Override $manual
        if ($win64) { return $win64 }
        Write-WarnLine "Still invalid: $manual"
    }

    throw 'Could not locate Palworld after several attempts.'
}

function Install-MapTextures {
    if ($SkipMaps) {
        Add-InstallWarning 'Skipped map textures (-SkipMaps). Map background will be blank until you add them.'
        return
    }

    if (-not (Test-Path -LiteralPath $MapsDir)) {
        New-Item -ItemType Directory -Path $MapsDir -Force | Out-Null
    }

    $failed = @()
    foreach ($file in $MapFiles) {
        $dest = Join-Path $MapsDir $file.Name
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -ge $file.MinBytes)) {
            Write-Ok "$($file.Name) already present"
            continue
        }
        try {
            Save-RemoteFile -Urls $file.Urls -Destination $dest -MinBytes $file.MinBytes
            Write-Ok "Downloaded $($file.Name)"
        } catch {
            $failed += $file.Name
            Write-WarnLine $_.Exception.Message
        }
    }

    if ($failed.Count -gt 0) {
        Add-InstallWarning ("Map download failed for: {0}. Overlay still works; drop webp files into companion\public\maps\ later." -f ($failed -join ', '))
        if (-not $Quiet -and -not (Read-YesNo 'Continue install without map textures?' $true)) {
            throw 'Map texture download aborted by user.'
        }
    }
}

function Install-CompanionDependencies {
    if ($SkipNpm) {
        Add-InstallWarning 'Skipped npm install (-SkipNpm). Run npm install in companion\ before launching.'
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $CompanionDir 'package.json'))) {
        throw "Companion app not found at $CompanionDir — are you running install.bat from the repo root?"
    }

    Refresh-ProcessPath
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-WarnLine 'npm missing after Node check — retrying Node setup...'
        Ensure-NodeJs
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm not found on PATH. Close this window and rerun install.bat.'
    }

    Push-Location $CompanionDir
    try {
        $ok = $false
        $strategies = @(
            { & npm install },
            {
                Write-WarnLine 'Retrying npm install after cache clean...'
                & npm cache clean --force 2>$null
                & npm install
            },
            {
                Write-WarnLine 'Retrying npm install with fresh node_modules...'
                if (Test-Path -LiteralPath 'node_modules') {
                    Remove-Item -LiteralPath 'node_modules' -Recurse -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path -LiteralPath 'package-lock.json') {
                    # keep lockfile; only wipe modules
                }
                & npm install
            }
        )

        foreach ($strategy in $strategies) {
            try {
                & $strategy
                if ($LASTEXITCODE -eq 0) {
                    $ok = $true
                    break
                }
                Write-WarnLine "npm exited with code $LASTEXITCODE"
            } catch {
                Write-WarnLine "npm install error: $($_.Exception.Message)"
            }
        }

        if (-not $ok) {
            throw 'npm install failed after retries. Check your internet / antivirus, then rerun install.bat.'
        }

        # Sanity: electron should exist for the overlay
        if (-not (Test-Path -LiteralPath (Join-Path $CompanionDir 'node_modules\electron'))) {
            Write-WarnLine 'electron package missing — running npm install electron...'
            & npm install electron --save
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $CompanionDir 'node_modules\electron'))) {
                throw 'Companion dependencies incomplete (electron missing).'
            }
        }

        Write-Ok 'Companion dependencies installed'
    } finally {
        Pop-Location
    }
}

function Expand-ZipToDirectory([string] $ZipPath, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Install-Ue4ss([string] $Win64Path) {
    if ($SkipUe4ss) {
        Add-InstallWarning 'Skipped UE4SS (-SkipUe4ss). Bridge will not run until UE4SS is installed.'
        return
    }

    $ue4ssDll = Join-Path $Win64Path 'UE4SS.dll'
    if (Test-Path -LiteralPath $ue4ssDll) {
        Write-Ok 'UE4SS already installed'
        return
    }

    if (-not (Read-YesNo 'UE4SS was not found. Download and install UE4SS v3.0.1 now?' $true)) {
        Add-InstallWarning 'UE4SS not installed. Live tracking will not work until you install it.'
        return
    }

    if (-not (Wait-ForPalworldClosed)) {
        Add-InstallWarning 'Palworld still running — UE4SS copy may fail. Close the game and rerun install.bat.'
    }

    $tempZip = Join-Path $env:TEMP "PalworldOverlay-UE4SS-$([guid]::NewGuid().ToString('N')).zip"
    $tempExtract = Join-Path $env:TEMP "PalworldOverlay-UE4SS-$([guid]::NewGuid().ToString('N'))"
    try {
        # Standard package only (not the zDEV build).
        $ue4ssUrl = $Ue4ssUrls | Where-Object { $_ -notmatch 'zDEV-' } | Select-Object -First 1
        Save-RemoteFile -Urls @($ue4ssUrl) -Destination $tempZip -MinBytes 500000
        Expand-ZipToDirectory -ZipPath $tempZip -Destination $tempExtract

        # Zip may extract flat or into a single root folder
        $sourceRoot = $tempExtract
        $entries = Get-ChildItem -LiteralPath $tempExtract -Force
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $innerDll = Join-Path $entries[0].FullName 'UE4SS.dll'
            if (Test-Path -LiteralPath $innerDll) {
                $sourceRoot = $entries[0].FullName
            }
        }

        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'UE4SS.dll'))) {
            throw 'UE4SS zip did not contain UE4SS.dll'
        }

        $settingsPath = Join-Path $Win64Path 'UE4SS-settings.ini'
        $preserveSettings = Test-Path -LiteralPath $settingsPath

        Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
            $target = Join-Path $Win64Path $_.Name
            if ($preserveSettings -and $_.Name -eq 'UE4SS-settings.ini') { return }
            if ($_.PSIsContainer) {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            }
        }

        if (-not (Test-Path -LiteralPath $ue4ssDll)) {
            throw 'UE4SS.dll missing after copy — check folder permissions / antivirus.'
        }
        Write-Ok 'UE4SS installed'
    } catch {
        Add-InstallWarning "UE4SS install failed: $($_.Exception.Message). Install manually from https://github.com/UE4SS-RE/RE-UE4SS/releases"
        if (-not $Quiet -and -not (Read-YesNo 'Continue without UE4SS? (map works, no live tracking)' $true)) {
            throw 'UE4SS install aborted by user.'
        }
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Enable-ModInModsTxt([string] $ModsTxt, [string] $Name) {
    $lines = @()
    if (Test-Path -LiteralPath $ModsTxt) {
        try {
            $lines = @(Get-Content -LiteralPath $ModsTxt -ErrorAction Stop)
        } catch {
            Write-WarnLine "Could not read mods.txt — recreating. ($($_.Exception.Message))"
            $lines = @()
        }
    }

    $pattern = "^\s*$([regex]::Escape($Name))\s*:"
    $updated = $false
    $output = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $updated = $true
            "$Name : 1"
        } else {
            $line
        }
    }

    if (-not $updated) {
        $output = @($output)
        if ($output.Count -gt 0 -and $output[-1] -ne '') { $output += '' }
        $output += "$Name : 1"
    }

    $modsDir = Split-Path -Parent $ModsTxt
    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    }

    Invoke-WithRetry -Label 'write mods.txt' -Attempts 3 -Action {
        Set-Content -LiteralPath $ModsTxt -Value $output -Encoding UTF8
    }
}

function Install-BridgeMod([string] $Win64Path) {
    if (-not (Test-Path -LiteralPath $BridgeSrc)) {
        throw "Bridge mod source not found at $BridgeSrc"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $BridgeSrc 'Scripts\main.lua'))) {
        throw "Bridge mod incomplete (Scripts\main.lua missing) at $BridgeSrc"
    }

    $null = Wait-ForPalworldClosed

    $modsDir = Join-Path $Win64Path 'Mods'
    $dest = Join-Path $modsDir $ModName

    Invoke-WithRetry -Label 'install bridge mod' -Attempts 3 -DelaySeconds 2 -Action {
        if (-not (Test-Path -LiteralPath $modsDir)) {
            New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        Copy-Item -LiteralPath $BridgeSrc -Destination $dest -Recurse -Force
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'Scripts\main.lua'))) {
            throw 'bridge copy incomplete'
        }
        Enable-ModInModsTxt -ModsTxt (Join-Path $modsDir 'mods.txt') -Name $ModName
    }

    # Verify enabled
    $modsTxt = Join-Path $modsDir 'mods.txt'
    if (-not (Select-String -LiteralPath $modsTxt -Pattern "$ModName\s*:\s*1" -Quiet)) {
        throw "Mod copied but not enabled in mods.txt — check $modsTxt"
    }

    Write-Ok "Installed $ModName"
}

function Ensure-AppDataDirectory {
    $appData = Join-Path $env:LOCALAPPDATA 'PalworldAssist'
    Invoke-WithRetry -Label 'create AppData folder' -Attempts 3 -Action {
        if (-not (Test-Path -LiteralPath $appData)) {
            New-Item -ItemType Directory -Path $appData -Force | Out-Null
        }
        # Touch a probe file to confirm write access
        $probe = Join-Path $appData '.write-test'
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force
    }
    Write-Ok "Ready $appData"
}

function Write-LaunchScripts {
    $startBat = Join-Path $RepoRoot 'start-overlay.bat'
    $content = @"
@echo off
setlocal
cd /d "%~dp0companion"
where npm >nul 2>&1
if errorlevel 1 (
  echo npm not found. Run install.bat first.
  pause
  exit /b 1
)
call npm run dev:app
if errorlevel 1 (
  echo.
  echo Overlay failed to start. Try: install.bat
  pause
)
"@
    Invoke-WithRetry -Label 'write start-overlay.bat' -Attempts 3 -Action {
        Set-Content -LiteralPath $startBat -Value $content -Encoding ASCII
    }
    Write-Ok 'Created start-overlay.bat'
}

function Start-CompanionApp {
    Refresh-ProcessPath
    Push-Location $CompanionDir
    try {
        & npm run dev:app
    } finally {
        Pop-Location
    }
}

function Test-RepoLayout {
    $required = @(
        (Join-Path $CompanionDir 'package.json'),
        (Join-Path $BridgeSrc 'Scripts\main.lua'),
        (Join-Path $BridgeSrc 'mod.json')
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Repo looks incomplete (missing $path). Re-download / git clone the full PalworldOverlay repo."
        }
    }
}

try {
    Initialize-Tls

    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'PalworldOverlay installer' -ForegroundColor White
        Write-Host '-------------------------' -ForegroundColor DarkGray
        Write-Host 'Auto-fixes: Node, downloads, npm, Palworld path, UE4SS, bridge mod.' -ForegroundColor DarkGray
    }

    Write-Step 'Checking repo files'
    Test-RepoLayout
    Write-Ok 'Repo layout OK'

    Write-Step 'Checking / installing Node.js'
    Ensure-NodeJs

    Write-Step 'Downloading map textures'
    Install-MapTextures

    Write-Step 'Installing companion app dependencies'
    Install-CompanionDependencies

    Write-Step 'Locating Palworld Win64 folder'
    $win64 = Prompt-PalworldPath -Initial $PalworldPath
    Write-Ok $win64

    Write-Step 'Installing UE4SS (if needed)'
    Install-Ue4ss -Win64Path $win64

    Write-Step 'Installing bridge mod'
    try {
        Install-BridgeMod -Win64Path $win64
    } catch {
        Add-InstallWarning "Bridge mod install failed: $($_.Exception.Message)"
        if (-not $Quiet -and -not (Read-YesNo 'Continue anyway? (you can copy bridge\PalworldAssistBridge into Mods manually)' $true)) {
            throw
        }
    }

    Write-Step 'Preparing local app data folder'
    Ensure-AppDataDirectory

    Write-Step 'Creating launcher'
    Write-LaunchScripts

    if (-not $Quiet) {
        Write-Host ''
        if ($script:InstallWarnings.Count -gt 0) {
            Write-Host 'Install finished with warnings:' -ForegroundColor Yellow
            foreach ($w in $script:InstallWarnings) {
                Write-Host "  - $w" -ForegroundColor Yellow
            }
            Write-Host ''
        } else {
            Write-Host 'Install complete!' -ForegroundColor Green
            Write-Host ''
        }
        Write-Host 'Next steps:' -ForegroundColor White
        Write-Host '  1. Run start-overlay.bat' -ForegroundColor DarkGray
        Write-Host '  2. Fully close Palworld, then relaunch with the overlay already running' -ForegroundColor DarkGray
        Write-Host '  3. Press F8 in-game to hide/show the map overlay' -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($Launch) {
        Write-Step 'Launching companion overlay'
        Start-CompanionApp
    }
} catch {
    Write-ErrLine $_.Exception.Message
    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'Recovery tips:' -ForegroundColor Yellow
        Write-Host '  - Right-click install.bat → Run as administrator' -ForegroundColor DarkGray
        Write-Host '  - Close Palworld completely, then rerun install.bat' -ForegroundColor DarkGray
        Write-Host '  - Check internet / antivirus blocking downloads' -ForegroundColor DarkGray
        Write-Host '  - Manual Node: https://nodejs.org/' -ForegroundColor DarkGray
        Write-Host '  - Manual UE4SS: https://github.com/UE4SS-RE/RE-UE4SS/releases' -ForegroundColor DarkGray
        Write-Host ''
    }
    exit 1
}
