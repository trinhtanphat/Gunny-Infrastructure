param(
  [string]$WebRoot='C:\Gunny-DDTank30\webroot',
  [string]$AuthoritativeRoot='C:\Gunny-DDTank30\external-sources\dk-khoado-Gunny-3.0\inetpub\wwwroot',
  [string]$LegacyRoot='C:\Gunny\GunnyFileExe',
  [string]$ManifestPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'resources\ddtank30-webshell-recovery.json'),
  [string]$BackupRoot='C:\Gunny-DDTank30\backups',
  [string]$ProbeBaseUrl='',
  [switch]$Force
)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if($manifest.schemaVersion-ne1){throw "Unsupported manifest schema: $($manifest.schemaVersion)"}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $BackupRoot "ddtank30-webshell-$stamp"
function Get-Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
foreach($asset in $manifest.assets){
  $base=if($asset.sourceKind-eq'authoritative-v30'){$AuthoritativeRoot}elseif($asset.sourceKind-eq'legacy-pinned'){$LegacyRoot}else{throw "Unknown source kind: $($asset.sourceKind)"}
  $source=Join-Path $base $asset.source
  $target=Join-Path $WebRoot $asset.target
  if(-not(Test-Path -LiteralPath $source)){throw "Missing source for $($asset.requestPath): $source"}
  if((Get-Item -LiteralPath $source).Length-ne[int64]$asset.size){throw "Source size mismatch for $($asset.requestPath)"}
  $sourceHash=Get-Sha $source
  if($sourceHash-ne[string]$asset.sha256){throw "Source hash mismatch for $($asset.requestPath): $sourceHash"}
  if(Test-Path -LiteralPath $target){
    $targetHash=Get-Sha $target
    if($targetHash-eq$sourceHash){Write-Host "RESOURCE_RECOVERY=SKIP path=$($asset.requestPath) sha256=$sourceHash"; continue}
    if(-not$Force){throw "Target differs for $($asset.requestPath); rerun with -Force after review"}
    $relative=$asset.target
    $backupPath=Join-Path $backup $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $backupPath) | Out-Null
    Copy-Item -LiteralPath $target -Destination $backupPath -Force
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
  Copy-Item -LiteralPath $source -Destination $target -Force
  $targetHash=Get-Sha $target
  if($targetHash-ne$sourceHash){throw "Post-copy hash mismatch for $($asset.requestPath)"}
  Write-Host "RESOURCE_RECOVERY=RESTORED path=$($asset.requestPath) sha256=$targetHash"
}
if($ProbeBaseUrl){
  foreach($asset in $manifest.assets){
    $url=$ProbeBaseUrl.TrimEnd('/')+$asset.requestPath
    $code=& curl.exe -sS -o NUL -w '%{http_code}' $url
    if($LASTEXITCODE-ne0 -or $code-ne'200'){throw "HTTP probe failed $code $url"}
    Write-Host "RESOURCE_PROBE=PASS status=200 path=$($asset.requestPath)"
  }
}
Write-Host "DDTANK30_WEBSHELL_RECOVERY=PASS assets=$(@($manifest.assets).Count) unresolved=$(@($manifest.unresolved).Count)"