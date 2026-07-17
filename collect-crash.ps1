#Requires -Version 5.1
<#
.SYNOPSIS
  Collect Palworld / UE4SS crash dumps into crash\<timestamp>\ (+ zip) for sharing.

.EXAMPLE
  .\collect-crash.ps1

.EXAMPLE
  .\collect-crash.ps1 -PalworldPath "D:\SteamLibrary\steamapps\common\Palworld"
#>
[CmdletBinding()]
param(
    [string] $PalworldPath = '',
    [int] $MaxDumps = 8,
    [switch] $Quiet,
    [switch] $NoZip,
    [switch] $OpenFolder
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$CrashRoot = Join-Path $RepoRoot 'crash'

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
        if (-not $libraries.Contains($steamRoot)) { [void] $libraries.Add($steamRoot) }
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        $content = Get-Content -LiteralPath $vdf -Raw
        foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
            $lib = $match.Groups[1].Value -replace '\\\\', '\'
            if (-not $libraries.Contains($lib)) { [void] $libraries.Add($lib) }
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
            'XboxGames\Palworld\Content\Pal\Binaries\Win64'
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

function Copy-Safe {
    param([string] $Source, [string] $DestDir, [string] $DestName = '')
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $name = if ($DestName) { $DestName } else { Split-Path -Leaf $Source }
    $dest = Join-Path $DestDir $name
    try {
        Copy-Item -LiteralPath $Source -Destination $dest -Force
        return $true
    } catch {
        Write-WarnLine "Could not copy $Source : $($_.Exception.Message)"
        return $false
    }
}

function Copy-TreeSafe {
    param([string] $SourceDir, [string] $DestDir)
    if (-not (Test-Path -LiteralPath $SourceDir)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($SourceDir.Length).TrimStart('\')
        $target = Join-Path $DestDir $rel
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        try {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            $count++
        } catch {
            Write-WarnLine "Skip $($_.Name): $($_.Exception.Message)"
        }
    }
    return $count
}

try {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'PalworldOverlay crash collector' -ForegroundColor White
        Write-Host '--------------------------------' -ForegroundColor DarkGray
    }

    Write-Step 'Locating Palworld Win64'
    $win64 = Find-PalworldWin64 -Override $PalworldPath
    if (-not $win64) {
        if ($Quiet) {
            throw 'Could not find Palworld. Pass -PalworldPath "C:\path\to\Palworld".'
        }
        Write-WarnLine 'Could not auto-detect Palworld.'
        $manual = Read-Host 'Palworld path (game root or Win64)'
        $win64 = Find-PalworldWin64 -Override $manual
        if (-not $win64) {
            throw "Invalid Palworld path: $manual"
        }
    }
    Write-Ok $win64

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pc = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($pc)) { $pc = 'unknown-pc' }
    $safePc = ($pc -replace '[^\w\-]+', '_')
    $outName = "${stamp}_${safePc}"
    $outDir = Join-Path $CrashRoot $outName
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Write-Ok "Output: $outDir"

    $copied = 0
    $manifest = [System.Collections.Generic.List[string]]::new()

    function Note([string] $Line) {
        [void] $manifest.Add($Line)
    }

    Note "collectedAt=$(Get-Date -Format o)"
    Note "computer=$pc"
    Note "user=$env:USERNAME"
    Note "win64=$win64"
    Note "repo=$RepoRoot"

    Write-Step 'Collecting UE4SS crash dumps (Win64\crash_*.dmp)'
    $dumpDir = Join-Path $outDir 'ue4ss-dumps'
    $dumps = @(Get-ChildItem -LiteralPath $win64 -Filter 'crash_*.dmp' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxDumps)
    if ($dumps.Count -eq 0) {
        Write-WarnLine 'No crash_*.dmp files found in Win64.'
        Note 'ue4ss-dumps=none'
    } else {
        New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
        foreach ($d in $dumps) {
            if (Copy-Safe -Source $d.FullName -DestDir $dumpDir) {
                $copied++
                Note ("dump={0} size={1} mtime={2:o}" -f $d.Name, $d.Length, $d.LastWriteTimeUtc)
                Write-Ok $d.Name
            }
        }
    }

    Write-Step 'Collecting UE4SS log + settings'
    $ue4ssDir = Join-Path $outDir 'ue4ss'
    New-Item -ItemType Directory -Path $ue4ssDir -Force | Out-Null
    foreach ($name in @('UE4SS.log', 'UE4SS-settings.ini', 'dwmapi.dll')) {
        $src = Join-Path $win64 $name
        if (Copy-Safe -Source $src -DestDir $ue4ssDir) {
            $copied++
            Write-Ok $name
            Note "ue4ss=$name"
        }
    }

    Write-Step 'Collecting Mods\mods.txt + PalworldAssistBridge'
    $modsDir = Join-Path $outDir 'mods'
    $modsTxt = Join-Path $win64 'Mods\mods.txt'
    if (Copy-Safe -Source $modsTxt -DestDir $modsDir) {
        $copied++
        Write-Ok 'mods.txt'
        Note 'mods=mods.txt'
    }
    $bridge = Join-Path $win64 'Mods\PalworldAssistBridge'
    if (Test-Path -LiteralPath $bridge) {
        $bridgeOut = Join-Path $modsDir 'PalworldAssistBridge'
        $n = Copy-TreeSafe -SourceDir $bridge -DestDir $bridgeOut
        $copied += $n
        Write-Ok "PalworldAssistBridge ($n files)"
        Note "bridgeFiles=$n"
        # Read version if present
        $modJson = Join-Path $bridge 'mod.json'
        if (Test-Path -LiteralPath $modJson) {
            try {
                $mj = Get-Content -LiteralPath $modJson -Raw | ConvertFrom-Json
                Note ("bridgeVersion={0}" -f $mj.mod_version)
            } catch {}
        }
    } else {
        Write-WarnLine 'PalworldAssistBridge mod folder not found.'
        Note 'bridge=missing'
    }

    Write-Step 'Collecting Unreal CrashContext (AppData)'
    $ueCrashRoot = Join-Path $env:LOCALAPPDATA 'Pal\Saved\Crashes'
    $ueOut = Join-Path $outDir 'unreal-crashes'
    if (Test-Path -LiteralPath $ueCrashRoot) {
        $folders = @(Get-ChildItem -LiteralPath $ueCrashRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3)
        if ($folders.Count -eq 0) {
            Write-WarnLine 'No Unreal crash folders found.'
            Note 'unreal-crashes=none'
        } else {
            foreach ($folder in $folders) {
                $dest = Join-Path $ueOut $folder.Name
                $n = Copy-TreeSafe -SourceDir $folder.FullName -DestDir $dest
                $copied += $n
                Write-Ok "$($folder.Name) ($n files)"
                Note "unrealCrash=$($folder.Name) files=$n"
            }
        }
    } else {
        Write-WarnLine "No folder at $ueCrashRoot"
        Note 'unreal-crashes=missing-root'
    }

    Write-Step 'Collecting PalworldAssist live.json (if present)'
    $assistDir = Join-Path $env:LOCALAPPDATA 'PalworldAssist'
    $assistOut = Join-Path $outDir 'palworldassist'
    foreach ($name in @('live.json', 'progress.json')) {
        $src = Join-Path $assistDir $name
        if (Copy-Safe -Source $src -DestDir $assistOut) {
            $copied++
            Write-Ok $name
            Note "assist=$name"
        }
    }

    # Optional: recent Windows Error Reporting dumps for Palworld (can be huge  -  only copy if small enough)
    Write-Step 'Checking Windows CrashDumps for Palworld (optional, size-capped)'
    $wer = Join-Path $env:LOCALAPPDATA 'CrashDumps'
    $werOut = Join-Path $outDir 'windows-crashdumps'
    if (Test-Path -LiteralPath $wer) {
        $werDumps = @(Get-ChildItem -LiteralPath $wer -Filter 'Palworld*.dmp' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 2)
        foreach ($d in $werDumps) {
            # Cap at 80 MB to keep zips Discord-friendly-ish; still large
            if ($d.Length -gt 80MB) {
                Write-WarnLine "Skip $($d.Name) ($([math]::Round($d.Length/1MB)) MB) - too large; Unreal/UE4SS dumps are enough."
                Note "werSkip=$($d.Name) size=$($d.Length)"
                continue
            }
            if (Copy-Safe -Source $d.FullName -DestDir $werOut) {
                $copied++
                Write-Ok $d.Name
                Note "wer=$($d.Name)"
            }
        }
    }

    $manifestPath = Join-Path $outDir 'manifest.txt'
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8
    Write-Ok 'Wrote manifest.txt'

    $zipPath = $null
    if (-not $NoZip) {
        Write-Step 'Creating zip'
        $zipPath = Join-Path $CrashRoot "$outName.zip"
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path $outDir -DestinationPath $zipPath -Force
        Write-Ok $zipPath
    }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host "Collected $copied file(s)." -ForegroundColor Green
        Write-Host "Folder: $outDir" -ForegroundColor White
        if ($zipPath) {
            Write-Host "Zip:    $zipPath" -ForegroundColor White
            Write-Host ''
            Write-Host 'Send the .zip to whoever is debugging (Discord / Drive / etc.).' -ForegroundColor DarkGray
        }
        Write-Host ''
        $open = Read-Host 'Open crash folder now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($open) -or $open -match '^[yY]') {
            Start-Process explorer.exe -ArgumentList $CrashRoot
        }
    } elseif ($OpenFolder) {
        Start-Process explorer.exe -ArgumentList $CrashRoot
    }
} catch {
    Write-ErrLine $_.Exception.Message
    exit 1
}
