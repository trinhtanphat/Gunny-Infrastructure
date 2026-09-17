[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\Gunny\GunnyFileExe',
    [string]$ReleaseZipUri = 'https://github.com/trinhtanphat/Resource/releases/download/runtime-v389-ruffle-recovery-assets-20260917/gunny-v389-ruffle-recovery-assets-20260917.zip',
    [string]$PackagePath = '',
    [string]$ExpectedSha256 = '769D059405E7C42463B9681CBAAD990C8292C4C56E2D2FBE34BB1FEA96F244C4',
    [int]$ExpectedFiles = 398,
    [string]$WorkRoot = '',
    [switch]$SkipBackup
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ('gunny-v389-ruffle-recovery-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $WorkRoot 'gunny-v389-ruffle-recovery-assets.zip'
    Invoke-WebRequest -Uri $ReleaseZipUri -OutFile $PackagePath -UseBasicParsing
} elseif (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "Ruffle recovery package not found: $PackagePath"
}
$packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($packageHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "Ruffle recovery package SHA256 mismatch: got $packageHash expected $ExpectedSha256"
}
$extractRoot = Join-Path $WorkRoot 'extract'
if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractRoot -Force
$sourceRoot = Join-Path $extractRoot 'image'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw 'Package does not contain image.' }
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File)
if ($sourceFiles.Count -ne $ExpectedFiles) { throw "Ruffle recovery file count mismatch: got $($sourceFiles.Count) expected $ExpectedFiles" }
$targetWeb = Join-Path $TargetRoot 'gunny'
$backupRoot = ''
if (-not $SkipBackup) {
    $backupRoot = Join-Path (Split-Path $TargetRoot -Parent) ('backups\ruffle-recovery-before-sync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$verified = 0
foreach ($src in $sourceFiles) {
    $rel = 'image\' + $src.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $dst = Join-Path $targetWeb $rel
    if (-not $SkipBackup -and (Test-Path -LiteralPath $dst -PathType Leaf)) {
        $backup = Join-Path $backupRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $backup -Parent) | Out-Null
        Copy-Item -LiteralPath $dst -Destination $backup -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
    if ((Get-Item -LiteralPath $dst).Length -ne $src.Length) { throw "Size mismatch after recovery deploy: $rel" }
    if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash) {
        throw "SHA256 mismatch after recovery deploy: $rel"
    }
    $verified++
}
Write-Host "GUNNY_V389_RUFFLE_RECOVERY_SYNC=PASS files=$verified backup=$backupRoot"
