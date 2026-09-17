[CmdletBinding()]
param(
    [string]$TargetRoot = 'C:\Gunny\GunnyFileExe',
    [string]$ManifestPath = '',
    [string]$SourceRepo = 'trinhtanphat/Resource',
    [string]$SourceRef = '43c21f53343cef61cf91180438bf594b2c8bd51b',
    [string]$BackupRoot = 'C:\Gunny\backups'
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot 'v389-farm-pet-manifest.tsv'
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Farm manifest missing: $ManifestPath"
}
$webRoot = Join-Path $TargetRoot 'gunny'
if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) {
    throw "Gunny web root missing: $webRoot"
}
$rows = @(Import-Csv -LiteralPath $ManifestPath -Delimiter "`t")
$tempRoot = Join-Path $env:TEMP ('gunny-v389-farm-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $BackupRoot ('farm-before-sync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
function Get-Sha([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function Get-RawUrl([string]$Path) {
    $segments = $Path.Replace('\','/').Split('/') | ForEach-Object {[uri]::EscapeDataString($_)}
    'https://raw.githubusercontent.com/' + $SourceRepo + '/' + $SourceRef + '/' + ($segments -join '/')
}
$restored = 0
$skipped = 0
try {
    foreach ($row in $rows) {
        $rel = ([string]$row.path).Replace('/','\')
        $target = Join-Path $webRoot $rel
        $wantedHash = ([string]$row.sha256).ToUpperInvariant()
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            if ((Get-Item -LiteralPath $target).Length -eq [int64]$row.bytes -and (Get-Sha $target) -eq $wantedHash) {
                $skipped++
                continue
            }
            $backupPath = Join-Path $backup $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $backupPath -Parent) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backupPath -Force
        }
        $temp = Join-Path $tempRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $temp -Parent) | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri (Get-RawUrl ([string]$row.path)) -OutFile $temp -TimeoutSec 30
        if ((Get-Item -LiteralPath $temp).Length -ne [int64]$row.bytes) {
            throw "Farm source size mismatch: $($row.path)"
        }
        if ((Get-Sha $temp) -ne $wantedHash) {
            throw "Farm source SHA256 mismatch: $($row.path)"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath $temp -Destination $target -Force
        & icacls.exe $target /inheritance:e /grant '*S-1-5-32-545:(RX)' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Farm ACL repair failed: $($row.path)" }
        if ((Get-Item -LiteralPath $target).Length -ne [int64]$row.bytes -or (Get-Sha $target) -ne $wantedHash) {
            throw "Farm post-copy verification failed: $($row.path)"
        }
        $restored++
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "GUNNY_V389_FARM_SYNC=PASS files=$($rows.Count) restored=$restored skipped=$skipped source=$SourceRepo@$SourceRef"
