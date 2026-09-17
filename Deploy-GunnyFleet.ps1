[CmdletBinding()]
param(
  [string]$InventoryPath=(Join-Path $PSScriptRoot 'fleet.json'),
  [switch]$Apply,
  [switch]$NoRestart,
  [switch]$SkipHttpProbe,
  [PSCredential]$Credential
)
$ErrorActionPreference='Stop'
$sync=Join-Path $PSScriptRoot 'Sync-GunnyInfraFleet.ps1'
$invoke=Join-Path $PSScriptRoot 'Invoke-GunnyFleet.ps1'
& $sync -InventoryPath $InventoryPath -Apply:$Apply -Credential $Credential
if(-not$?){throw 'Fleet sync failed.'}
& $invoke -InventoryPath $InventoryPath -Apply:$Apply -NoRestart:$NoRestart -SkipHttpProbe:$SkipHttpProbe -Credential $Credential
if(-not$?){throw 'Fleet apply failed.'}
if($Apply){Write-Host 'GUNNY_FLEET_DEPLOY=PASS'}else{Write-Host 'GUNNY_FLEET_VALIDATE_ONLY=PASS'}