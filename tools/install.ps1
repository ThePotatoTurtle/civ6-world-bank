[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ModsPath,
    [switch]$DevOnly,
    [switch]$DryRun,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'

# Explicit destination is intentional: Windows Documents is redirected on this PC.
if (Get-Process -Name 'CivilizationVI*' -ErrorAction SilentlyContinue) {
    throw 'Civilization VI is running. Quit to desktop before installing.'
}
if (-not (Test-Path -LiteralPath $ModsPath -PathType Container)) {
    throw 'ModsPath must be an existing, explicitly confirmed Mods directory.'
}
$resolvedMods = (Resolve-Path -LiteralPath $ModsPath).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
$repoRoot = Split-Path -Parent $PSScriptRoot
& $Python (Join-Path $PSScriptRoot 'check_all.py')
if ($LASTEXITCODE -ne 0) { throw 'Offline source checks failed; no files copied.' }
$modNames = @('WBL_Dev')
if (-not $DevOnly -and (Test-Path -LiteralPath (Join-Path $repoRoot 'WBL\WBL.modinfo'))) {
    $modNames = @('WBL', 'WBL_Dev')
}
foreach ($modName in $modNames) {
    $source = Join-Path $repoRoot $modName
    $destination = [IO.Path]::GetFullPath((Join-Path $resolvedMods $modName))
    if ((Split-Path -Parent $destination) -ne $resolvedMods -or (Split-Path -Leaf $destination) -ne $modName) {
        throw 'Resolved target is outside the confirmed ModsPath.'
    }
    $manifestName = "$modName.modinfo"
    [xml]$sourceManifest = Get-Content -LiteralPath (Join-Path $source $manifestName) -Raw
    if (Test-Path -LiteralPath $destination) {
        $existing = Get-Item -LiteralPath $destination -Force
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse-point destination: $destination" }
        $existingManifest = Join-Path $destination $manifestName
        if (-not (Test-Path -LiteralPath $existingManifest -PathType Leaf)) { throw "Existing folder has no owned manifest: $destination" }
        [xml]$oldManifest = Get-Content -LiteralPath $existingManifest -Raw
        if ($oldManifest.Mod.id -ne $sourceManifest.Mod.id) { throw "Existing folder belongs to a different mod: $destination" }
    }
    $files = @(& $Python (Join-Path $PSScriptRoot 'check_all.py') --list-manifest $source)
    if ($LASTEXITCODE -ne 0) { throw 'Invalid source manifest; no files copied.' }
    foreach ($relative in $files) {
        $sourceFile = Join-Path $source $relative
        $targetFile = [IO.Path]::GetFullPath((Join-Path $destination $relative))
        if (-not $targetFile.StartsWith($destination + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'File escaped the owned mod folder.' }
        # Do not traverse reparse points inside an otherwise owned mod directory.
        $probe = Split-Path -Parent $targetFile
        while ($probe.Length -ge $destination.Length) {
            if (Test-Path -LiteralPath $probe) {
                if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $probe" }
            }
            if ($probe -eq $destination) { break }
            $probe = Split-Path -Parent $probe
        }
        if (Test-Path -LiteralPath $targetFile) {
            if ((Get-Item -LiteralPath $targetFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $targetFile" }
        }
        if ($DryRun) { Write-Output "DRY RUN: $sourceFile -> $targetFile"; continue }
        if ($PSCmdlet.ShouldProcess($targetFile, 'Copy manifest file')) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force
            Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
            if ((Get-FileHash -LiteralPath $sourceFile).Hash -ne (Get-FileHash -LiteralPath $targetFile).Hash) { throw "Installed byte mismatch: $relative" }
        }
    }
}
# No delete: leave unrelated files alone, including files from a previous owned version.
Write-Output $(if ($DryRun -or $WhatIfPreference) { 'Dry run complete. No mod files copied.' } else { 'Installed manifest files; byte comparison passed.' })
