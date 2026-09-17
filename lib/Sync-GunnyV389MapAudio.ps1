[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\Gunny\GunnyFileExe',
    [string]$ReleaseZipUri = 'https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-map-audio-20260917/gunny-v389-map-audio-20260917.zip',
    [string]$PackagePath = '',
    [string]$ExpectedSha256 = 'B0D5BDE9B741273AD2A66777D81DDFB4C0C9F932AF2ABB3436AD54EEE44529AB',
    [int]$ExpectedFiles = 179,
    [string]$WorkRoot = '',
    [switch]$SkipBackup,
    [string]$HttpBaseUrl = ''
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ('gunny-v389-map-audio-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $WorkRoot 'gunny-v389-map-audio.zip'
    Invoke-WebRequest -Uri $ReleaseZipUri -OutFile $PackagePath -UseBasicParsing
} elseif (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Map audio package not found: $PackagePath"
}
$packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $packageHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "Map audio package SHA256 mismatch: got $packageHash expected $ExpectedSha256"
}

$extractRoot = Join-Path $WorkRoot 'extract'
if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractRoot -Force
$sourceSound = Join-Path $extractRoot 'sound'
if (-not (Test-Path -LiteralPath $sourceSound -PathType Container)) { throw 'Package does not contain sound.' }

$sourceFiles = @(Get-ChildItem -LiteralPath $sourceSound -File | Sort-Object Name)
if ($sourceFiles.Count -ne $ExpectedFiles) {
    throw "Map audio file count mismatch: got $($sourceFiles.Count) expected $ExpectedFiles"
}
$badNames = @($sourceFiles | Where-Object { $_.Name -notmatch '^\d+\.mp3$' })
if ($badNames.Count -gt 0) { throw "Unexpected map audio filenames: $($badNames.Name -join ', ')" }

$targetSound = Join-Path $TargetRoot 'gunny\sound'
New-Item -ItemType Directory -Force -Path $targetSound | Out-Null
$backupRoot = ''
if (-not $SkipBackup) {
    $backupRoot = Join-Path (Split-Path $TargetRoot -Parent) ('backups\map-audio-before-fullsync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($src in $sourceFiles) {
        $existing = Join-Path $targetSound $src.Name
        if (Test-Path -LiteralPath $existing -PathType Leaf) {
            $backup = Join-Path $backupRoot $src.Name
            New-Item -ItemType Directory -Force -Path (Split-Path $backup -Parent) | Out-Null
            Copy-Item -LiteralPath $existing -Destination $backup -Force
        }
    }
}

$robocopyArgs = @($sourceSound, $targetSound, '/E', '/R:1', '/W:1', '/MT:16', '/NFL', '/NDL', '/NP', '/BYTES')
& robocopy @robocopyArgs | Out-Host
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -gt 7) { throw "robocopy failed with exit code $robocopyCode" }

$verified = 0
foreach ($src in $sourceFiles) {
    $dst = Join-Path $targetSound $src.Name
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { throw "Missing deployed map audio: $($src.Name)" }
    if ((Get-Item -LiteralPath $dst).Length -ne $src.Length) { throw "Size mismatch after deploy: $($src.Name)" }
    $sourceHash = (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) { throw "SHA256 mismatch after deploy: $($src.Name)" }
    $verified++
}
Write-Host "PASS map audio file verification: $verified files"
$serverMapRoot = Join-Path $TargetRoot 'SERVER\Road\map'
if (Test-Path -LiteralPath $serverMapRoot -PathType Container) {
    $serverMapIds = @(Get-ChildItem -LiteralPath $serverMapRoot -Directory | Select-Object -ExpandProperty Name)
    $serverMapSet = @{}; foreach ($id in $serverMapIds) { $serverMapSet[[string]$id] = $true }
    $orphans = @($sourceFiles | ForEach-Object { $_.BaseName } | Where-Object { -not $serverMapSet.ContainsKey($_) })
    if ($orphans.Count -gt 0) { throw "Audio package contains non-server map ids: $($orphans -join ', ')" }
    Write-Host "PASS map audio/server id coverage: $($sourceFiles.Count) audio ids are valid server maps"
}

if (-not [string]::IsNullOrWhiteSpace($HttpBaseUrl)) {
    $probeCount = 0
    foreach ($src in $sourceFiles) {
        $uri = $HttpBaseUrl.TrimEnd('/') + '/Gunny/sound/' + $src.Name
        $response = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing -TimeoutSec 20
        if ($response.StatusCode -ne 200) { throw "HTTP probe failed $uri status=$($response.StatusCode)" }
        $probeCount++
    }
    Write-Host "PASS HTTP map audio coverage: $probeCount probes"
}

Write-Host "GUNNY_V389_MAP_AUDIO_SYNC=PASS files=$verified robocopy=$robocopyCode backup=$backupRoot"
