#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot installer for PalworldOverlay (companion app + UE4SS bridge mod).

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
    [switch] $Launch,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$CompanionDir = Join-Path $RepoRoot 'companion'
$MapsDir = Join-Path $CompanionDir 'public\maps'
$BridgeSrc = Join-Path $RepoRoot 'bridge\PalworldAssistBridge'
$ModName = 'PalworldAssistBridge'
$Ue4ssUrl = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip'
$MapUrls = @{
    'palworld-map.webp'     = 'https://raw.githubusercontent.com/amantu-qbit/palworld-server-manager/main/public/palworld-map.webp'
    'palworld-treemap.webp' = 'https://raw.githubusercontent.com/amantu-qbit/palworld-server-manager/main/public/palworld-treemap.webp'
}

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

function Read-YesNo([string] $Prompt, [bool] $Default = $true) {
    if ($Quiet) { return $Default }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^[yY]'
}

function Get-NodeCommand {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw "Node.js was not found. Install Node.js 20+ from https://nodejs.org/ and rerun install.ps1"
    }
    $versionText = & node -v
    if ($versionText -match 'v?(\d+)') {
        $major = [int] $Matches[1]
        if ($major -lt 20) {
            throw "Node.js $versionText found, but 20+ is required."
        }
    }
    return $node.Source
}

function Resolve-Win64Path([string] $InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $null }
    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction SilentlyContinue
    if (-not $resolved) { return $null }
    $path = $resolved.Path

    if (Test-Path -LiteralPath (Join-Path $path 'Palworld-Win64-Shipping.exe')) {
        return $path
    }
    if (Test-Path -LiteralPath (Join-Path $path 'UE4SS.dll')) {
        return $path
    }

    $nested = Join-Path $path 'Pal\Binaries\Win64'
    if (Test-Path -LiteralPath $nested) {
        return (Resolve-Path -LiteralPath $nested).Path
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

    foreach ($drive in @('C', 'D', 'E', 'F', 'G')) {
        [void] $candidates.Add("${drive}:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64")
        [void] $candidates.Add("${drive}:\Program Files (x86)\Steam\steamapps\common\Palworld\Pal\Binaries\Win64")
        [void] $candidates.Add("${drive}:\Program Files\Steam\steamapps\common\Palworld\Pal\Binaries\Win64")
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Save-RemoteFile([string] $Url, [string] $Destination) {
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not $Quiet) {
        Write-Host "    downloading $(Split-Path -Leaf $Destination) ..."
    }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Install-MapTextures {
    if ($SkipMaps) {
        Write-WarnLine 'Skipping map texture download (-SkipMaps).'
        return
    }

    if (-not (Test-Path -LiteralPath $MapsDir)) {
        New-Item -ItemType Directory -Path $MapsDir -Force | Out-Null
    }

    foreach ($entry in $MapUrls.GetEnumerator()) {
        $dest = Join-Path $MapsDir $entry.Key
        if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) {
            Write-Ok "$($entry.Key) already present"
            continue
        }
        Save-RemoteFile -Url $entry.Value -Destination $dest
        Write-Ok "Downloaded $($entry.Key)"
    }
}

function Install-CompanionDependencies {
    if ($SkipNpm) {
        Write-WarnLine 'Skipping npm install (-SkipNpm).'
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $CompanionDir 'package.json'))) {
        throw "Companion app not found at $CompanionDir"
    }

    Push-Location $CompanionDir
    try {
        & npm install
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed with exit code $LASTEXITCODE"
        }
        Write-Ok 'Companion dependencies installed'
    } finally {
        Pop-Location
    }
}

function Expand-ZipToDirectory([string] $ZipPath, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Install-Ue4ss([string] $Win64Path) {
    if ($SkipUe4ss) {
        Write-WarnLine 'Skipping UE4SS install (-SkipUe4ss).'
        return
    }

    $ue4ssDll = Join-Path $Win64Path 'UE4SS.dll'
    if (Test-Path -LiteralPath $ue4ssDll) {
        Write-Ok 'UE4SS already installed'
        return
    }

    if (-not (Read-YesNo 'UE4SS was not found. Download and install UE4SS v3.0.1 now?' $true)) {
        Write-WarnLine 'UE4SS not installed. The bridge mod will not work until UE4SS is installed manually.'
        return
    }

    $tempZip = Join-Path $env:TEMP "PalworldOverlay-UE4SS-$([guid]::NewGuid().ToString('N')).zip"
    $tempExtract = Join-Path $env:TEMP "PalworldOverlay-UE4SS-$([guid]::NewGuid().ToString('N'))"
    try {
        Save-RemoteFile -Url $Ue4ssUrl -Destination $tempZip
        Expand-ZipToDirectory -ZipPath $tempZip -Destination $tempExtract

        $settingsPath = Join-Path $Win64Path 'UE4SS-settings.ini'
        $preserveSettings = Test-Path -LiteralPath $settingsPath

        Get-ChildItem -LiteralPath $tempExtract -Force | ForEach-Object {
            $target = Join-Path $Win64Path $_.Name
            if ($preserveSettings -and $_.Name -eq 'UE4SS-settings.ini') {
                return
            }
            if ($_.PSIsContainer) {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            }
        }
        Write-Ok 'UE4SS installed'
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
        if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force }
    }
}

function Enable-ModInModsTxt([string] $ModsTxt, [string] $Name) {
    $lines = @()
    if (Test-Path -LiteralPath $ModsTxt) {
        $lines = @(Get-Content -LiteralPath $ModsTxt)
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
        if ($output.Count -gt 0 -and $output[-1] -ne '') {
            $output += ''
        }
        $output += "$Name : 1"
    }

    $modsDir = Split-Path -Parent $ModsTxt
    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    }

    Set-Content -LiteralPath $ModsTxt -Value $output -Encoding UTF8
}

function Install-BridgeMod([string] $Win64Path) {
    if (-not (Test-Path -LiteralPath $BridgeSrc)) {
        throw "Bridge mod source not found at $BridgeSrc"
    }

    $modsDir = Join-Path $Win64Path 'Mods'
    $dest = Join-Path $modsDir $ModName

    if (-not (Test-Path -LiteralPath $modsDir)) {
        New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }

    Copy-Item -LiteralPath $BridgeSrc -Destination $dest -Recurse -Force
    Enable-ModInModsTxt -ModsTxt (Join-Path $modsDir 'mods.txt') -Name $ModName
    Write-Ok "Installed $ModName to $dest"
}

function Ensure-AppDataDirectory {
    $appData = Join-Path $env:LOCALAPPDATA 'PalworldAssist'
    if (-not (Test-Path -LiteralPath $appData)) {
        New-Item -ItemType Directory -Path $appData -Force | Out-Null
    }
    Write-Ok "Ready $appData"
}

function Write-LaunchScripts {
    $startBat = Join-Path $RepoRoot 'start-overlay.bat'
    @"
@echo off
cd /d "%~dp0companion"
call npm run dev:app
"@ | Set-Content -LiteralPath $startBat -Encoding ASCII

    Write-Ok 'Created start-overlay.bat'
}

function Start-CompanionApp {
    Push-Location $CompanionDir
    try {
        & npm run dev:app
    } finally {
        Pop-Location
    }
}

try {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'PalworldOverlay installer' -ForegroundColor White
        Write-Host '-------------------------' -ForegroundColor DarkGray
    }

    Write-Step 'Checking Node.js'
    $null = Get-NodeCommand
    Write-Ok 'Node.js OK'

    Write-Step 'Downloading map textures'
    Install-MapTextures

    Write-Step 'Installing companion app dependencies'
    Install-CompanionDependencies

    Write-Step 'Locating Palworld Win64 folder'
    $win64 = Find-PalworldWin64 -Override $PalworldPath
    if (-not $win64) {
        if ($Quiet) {
            throw 'Could not find Palworld. Pass -PalworldPath "C:\path\to\Palworld".'
        }
        Write-WarnLine 'Could not auto-detect Palworld.'
        Write-Host '    Paste your Palworld install folder (game root or ...\Pal\Binaries\Win64):' -ForegroundColor DarkGray
        $manual = Read-Host 'Palworld path'
        $win64 = Find-PalworldWin64 -Override $manual
        if (-not $win64) {
            throw "Invalid Palworld path: $manual"
        }
    }
    Write-Ok $win64

    Write-Step 'Installing UE4SS (if needed)'
    Install-Ue4ss -Win64Path $win64

    Write-Step 'Installing bridge mod'
    Install-BridgeMod -Win64Path $win64

    Write-Step 'Preparing local app data folder'
    Ensure-AppDataDirectory

    Write-Step 'Creating launcher'
    Write-LaunchScripts

    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'Install complete!' -ForegroundColor Green
        Write-Host ''
        Write-Host 'Next steps:' -ForegroundColor White
        Write-Host '  1. Run start-overlay.bat (or: cd companion && npm run dev:app)' -ForegroundColor DarkGray
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
    exit 1
}
