param(
  [string]$WebRoot='C:\Gunny\GunnyFileExe\gunny',
  [string]$ManifestPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'resources\gunny-v389-residual-recovery.json'),
  [string]$SourceRoot='',
  [string]$BackupRoot='C:\Gunny\backups',
  [string]$ProbeBaseUrl='',
  [switch]$Force
)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if($manifest.schemaVersion-ne1){throw "Unsupported manifest schema: $($manifest.schemaVersion)"}
if($manifest.family-ne'Gunny-v389/5-year'){throw "Unexpected manifest family: $($manifest.family)"}
$tempRoot=Join-Path $env:TEMP ("gunny-v389-recovery-"+[guid]::NewGuid().ToString('N'))
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $BackupRoot "gunny-v389-residual-$stamp"
function Get-Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
try {
  if(-not$SourceRoot){New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null}
  foreach($asset in $manifest.assets){
    if($SourceRoot){
      $source=Join-Path $SourceRoot ([string]$asset.source).Replace('/','\')
    } else {
      $source=Join-Path $tempRoot ([string]$asset.source).Replace('/','\')
      New-Item -ItemType Directory -Force -Path (Split-Path $source) | Out-Null
      $sourceRepo=if($asset.PSObject.Properties.Name -contains 'sourceRepo' -and $asset.sourceRepo){[string]$asset.sourceRepo}else{[string]$manifest.sourceRepo}
      $sourceRef=if($asset.PSObject.Properties.Name -contains 'sourceRef' -and $asset.sourceRef){[string]$asset.sourceRef}else{[string]$manifest.sourceRef}
      $url="https://raw.githubusercontent.com/$sourceRepo/$sourceRef/$($asset.source)"
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $source -TimeoutSec 30
    }
    if(-not(Test-Path -LiteralPath $source)){throw "Missing source for $($asset.requestPath): $source"}
    if((Get-Item -LiteralPath $source).Length-ne[int64]$asset.size){throw "Source size mismatch for $($asset.requestPath)"}
    $sourceHash=Get-Sha $source
    if($sourceHash-ne[string]$asset.sha256){throw "Source hash mismatch for $($asset.requestPath): $sourceHash"}
    $target=Join-Path $WebRoot ([string]$asset.target)
    if(Test-Path -LiteralPath $target){
      $targetHash=Get-Sha $target
      if($targetHash-eq$sourceHash){Write-Host "V389_RESOURCE_RECOVERY=SKIP path=$($asset.requestPath) sha256=$sourceHash";continue}
      if(-not$Force){throw "Target differs for $($asset.requestPath); rerun with -Force after review"}
      $backupPath=Join-Path $backup ([string]$asset.target)
      New-Item -ItemType Directory -Force -Path (Split-Path $backupPath) | Out-Null
      Copy-Item -LiteralPath $target -Destination $backupPath -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    $targetHash=Get-Sha $target
    if($targetHash-ne$sourceHash){throw "Post-copy hash mismatch for $($asset.requestPath)"}
    Write-Host "V389_RESOURCE_RECOVERY=RESTORED path=$($asset.requestPath) sha256=$targetHash"
  }
  if($ProbeBaseUrl){
    foreach($asset in $manifest.assets){
      $url=$ProbeBaseUrl.TrimEnd('/')+$asset.requestPath
      $response=Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -TimeoutSec 10
      if([int]$response.StatusCode-ne200){throw "HTTP probe failed $($response.StatusCode) $url"}
      Write-Host "V389_RESOURCE_PROBE=PASS status=200 path=$($asset.requestPath)"
    }
  }
  Write-Host "GUNNY_V389_RESIDUAL_RECOVERY=PASS assets=$(@($manifest.assets).Count)"
} finally {
  if((-not$SourceRoot) -and (Test-Path -LiteralPath $tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
