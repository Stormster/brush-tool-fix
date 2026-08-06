<#
.SYNOPSIS
    Copies the mod from this repo into the Zomboid mods folder and the Workshop
    staging folder.

.DESCRIPTION
    Project Zomboid's mod scanner treats NTFS junctions and symlinks as files
    rather than directories, so a linked mod folder fails to load and a linked
    Workshop folder is rejected with "Files are not allowed in the Contents/mods/
    folder". Everything here must be a real copy; this script mirrors instead of
    linking and deletes any reparse point it finds in a destination.

.PARAMETER Watch
    Stay running and re-sync whenever a file under BrushToolSaveFix/ changes.

.EXAMPLE
    ./tools/sync.ps1
    ./tools/sync.ps1 -Watch
#>
[CmdletBinding()]
param(
    [switch]$Watch
)

$ErrorActionPreference = 'Stop'

$modName    = 'BrushToolSaveFix'
$repo       = Split-Path -Parent $PSScriptRoot
$source     = Join-Path $repo $modName
$metaSource = Join-Path $repo 'workshop'
$zomboid    = Join-Path $env:USERPROFILE 'Zomboid'
$modsDest   = Join-Path $zomboid "mods\$modName"
$wsRoot     = Join-Path $zomboid "Workshop\$modName"
$wsModDest  = Join-Path $wsRoot "Contents\mods\$modName"

# workshop.txt and preview.png are both mandatory; PZ hides the upload button
# without them.
$metaFiles = @('workshop.txt', 'preview.png', 'STEAM_DESCRIPTION.txt', 'IMAGES.txt')

function Test-ReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $attributes = (Get-Item -LiteralPath $Path -Force).Attributes
    return [bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function New-RealDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-ReparsePoint $Path) {
        # rmdir unlinks a junction without touching the directory it points at.
        cmd /c rmdir "$Path" | Out-Null
        Write-Host "  unlinked $Path" -ForegroundColor Yellow
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Sync-Tree {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    New-RealDirectory $To
    robocopy $From $To /MIR /NFL /NDL /NJH /NJS /NP /NC /NS /XD '.git' | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE ($From -> $To)"
    }
}

function Sync-Metadata {
    New-RealDirectory $wsRoot
    foreach ($name in $metaFiles) {
        $from = Join-Path $metaSource $name
        if (-not (Test-Path -LiteralPath $from)) {
            Write-Warning "missing $from"
            continue
        }
        $to = Join-Path $wsRoot $name
        if (Test-ReparsePoint $to) {
            Remove-Item -LiteralPath $to -Force
            Write-Host "  unlinked $to" -ForegroundColor Yellow
        }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory)][string]$Root)
    $links = Get-ChildItem -LiteralPath $Root -Recurse -Force |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
    if ($links) {
        throw "reparse points remain, PZ will reject these: $($links.FullName -join ', ')"
    }
}

function Sync-All {
    $version = (Select-String -Path (Join-Path $source '42\mod.info') -Pattern '^modversion=(.+)$').Matches.Groups[1].Value
    Write-Host "syncing $modName $version" -ForegroundColor Cyan

    Sync-Tree -From $source -To $modsDest
    Sync-Tree -From $source -To $wsModDest
    Sync-Metadata

    Assert-NoReparsePoints $modsDest
    Assert-NoReparsePoints $wsRoot

    Write-Host "  mods     -> $modsDest" -ForegroundColor Green
    Write-Host "  workshop -> $wsRoot" -ForegroundColor Green
}

Sync-All

if ($Watch) {
    Write-Host "watching $source (Ctrl+C to stop)" -ForegroundColor Cyan
    $watcher = New-Object System.IO.FileSystemWatcher $source, '*.*'
    $watcher.IncludeSubdirectories = $true
    try {
        while ($true) {
            $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
            if ($change.TimedOut) { continue }
            # Editors often write a file in several bursts; let them settle.
            Start-Sleep -Milliseconds 400
            Sync-All
        }
    }
    finally {
        $watcher.Dispose()
    }
}
