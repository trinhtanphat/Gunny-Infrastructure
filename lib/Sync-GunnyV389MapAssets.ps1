[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\Gunny\GunnyFileExe',
    [string]$ReleaseZipUri = 'https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-map-assets-20260917/gunny-v389-map-assets-20260917.zip',
    [string]$PackagePath = '',
    [string]$ExpectedSha256 = '2788692DD5315DE5DCDFF7166FFB4F50462A07E1BD450A2D491326760D6FFECD',
    [int]$ExpectedMapDirs = 378,
    [int]$ExpectedFiles = 1719,
    [string]$WorkRoot = '',
    [switch]$SkipBackup,
    [string]$HttpBaseUrl = ''
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ('gunny-v389-map-assets-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $WorkRoot 'gunny-v389-map-assets.zip'
    Invoke-WebRequest -Uri $ReleaseZipUri -OutFile $PackagePath -UseBasicParsing
} elseif (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Map asset package not found: $PackagePath"
}

$packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $packageHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "Map asset package SHA256 mismatch: got $packageHash expected $ExpectedSha256"
}

$extractRoot = Join-Path $WorkRoot 'extract'
if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractRoot -Force
$sourceMap = Join-Path $extractRoot 'image\map'
if (-not (Test-Path -LiteralPath $sourceMap -PathType Container)) { throw 'Package does not contain image\map.' }

$sourceDirs = @(Get-ChildItem -LiteralPath $sourceMap -Directory)
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceMap -Recurse -File)
if ($sourceDirs.Count -ne $ExpectedMapDirs) {
    throw "Map directory count mismatch: got $($sourceDirs.Count) expected $ExpectedMapDirs"
}
if ($sourceFiles.Count -ne $ExpectedFiles) {
    throw "Map file count mismatch: got $($sourceFiles.Count) expected $ExpectedFiles"
}

$targetMap = Join-Path $TargetRoot 'gunny\image\map'
New-Item -ItemType Directory -Force -Path $targetMap | Out-Null
$backupRoot = ''
if (-not $SkipBackup) {
    $backupRoot = Join-Path (Split-Path $TargetRoot -Parent) ('backups\map-assets-before-fullsync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($src in $sourceFiles) {
        $rel = $src.FullName.Substring($sourceMap.Length).TrimStart('\')
        $existing = Join-Path $targetMap $rel
        if (Test-Path -LiteralPath $existing -PathType Leaf) {
            $backup = Join-Path $backupRoot $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $backup -Parent) | Out-Null
            Copy-Item -LiteralPath $existing -Destination $backup -Force
        }
    }
}

$robocopyArgs = @($sourceMap, $targetMap, '/E', '/R:1', '/W:1', '/MT:16', '/NFL', '/NDL', '/NP', '/BYTES')
& robocopy @robocopyArgs | Out-Host
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -gt 7) { throw "robocopy failed with exit code $robocopyCode" }

$verified = 0
foreach ($src in $sourceFiles) {
    $rel = $src.FullName.Substring($sourceMap.Length).TrimStart('\')
    $dst = Join-Path $targetMap $rel
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "Missing deployed map asset: $rel" }
    $dstItem = Get-Item -LiteralPath $dst
    if ($dstItem.Length -ne $src.Length) { throw "Size mismatch after deploy: $rel" }
    $sourceHash = (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) { throw "SHA256 mismatch after deploy: $rel" }
    $verified++
}
Write-Host "PASS map asset file verification: $verified files"
$serverMapRoot = Join-Path $TargetRoot 'SERVER\Road\map'
if (Test-Path -LiteralPath $serverMapRoot -PathType Container) {
    $serverMapIds = @(Get-ChildItem -LiteralPath $serverMapRoot -Directory | Select-Object -ExpandProperty Name)
    $missingMapDirs = @($serverMapIds | Where-Object { -not (Test-Path -LiteralPath (Join-Path $targetMap $_) -PathType Container) })
    if ($missingMapDirs.Count -gt 0) {
        throw "Web map coverage missing $($missingMapDirs.Count) server map directories: $($missingMapDirs -join ', ')"
    }
    Write-Host "PASS server/web map coverage: $($serverMapIds.Count) map directories"
}

if (-not [string]::IsNullOrWhiteSpace($HttpBaseUrl)) {
    $probeCount = 0
    foreach ($dir in $sourceDirs) {
        $probe = Get-ChildItem -LiteralPath $dir.FullName -File | Sort-Object Name | Select-Object -First 1
        if (-not $probe) { throw "Map directory has no probe file: $($dir.Name)" }
        $rel = $probe.FullName.Substring($sourceMap.Length).TrimStart('\').Replace('\','/')
        $uri = $HttpBaseUrl.TrimEnd('/') + '/Gunny/image/map/' + $rel
        $response = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing -TimeoutSec 20
        if ($response.StatusCode -ne 200) { throw "HTTP probe failed $uri status=$($response.StatusCode)" }
        $probeCount++
    }
    Write-Host "PASS HTTP map coverage: $probeCount map probes"
}

Write-Host "GUNNY_V389_MAP_ASSET_SYNC=PASS maps=$($sourceDirs.Count) files=$verified robocopy=$robocopyCode backup=$backupRoot"
