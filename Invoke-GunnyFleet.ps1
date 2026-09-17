[CmdletBinding()]
param(
  [string]$InventoryPath=(Join-Path $PSScriptRoot 'fleet.json'),
  [switch]$Apply,
  [switch]$NoRestart,
  [switch]$SkipHttpProbe,
  [PSCredential]$Credential
)
$ErrorActionPreference='Stop'
if(-not(Test-Path $InventoryPath)){throw "Fleet inventory missing: $InventoryPath"}
$inventory=Get-Content $InventoryPath -Raw|ConvertFrom-Json
$servers=@($inventory.servers|Where-Object{$_.enabled})
if($servers.Count-eq0){throw 'Fleet inventory has no enabled servers.'}
foreach($s in $servers){
  $infraRoot=if($s.infraRoot){[string]$s.infraRoot}else{'C:\Gunny-Infra'}
  Write-Host "FLEET_APPLY_PLAN name=$($s.name) computer=$($s.computerName) host=$($s.publicHost) apply=$Apply"
  if(-not$Apply){continue}
  $local=([string]$s.computerName -in @('.', 'localhost', [Environment]::MachineName, $env:COMPUTERNAME))
  if($local){
    & (Join-Path $infraRoot 'Apply-AllGunnyInstances.ps1') -ConfigPath (Join-Path $infraRoot 'server-instance.json') -Apply -RestartChangedStacks:(-not$NoRestart) -SkipHttpProbe:$SkipHttpProbe
  } else {
    $args=@{ComputerName=[string]$s.computerName;ErrorAction='Stop'};if($Credential){$args.Credential=$Credential}
    Invoke-Command @args -ScriptBlock {param($r,$nr,$skip) & (Join-Path $r 'Apply-AllGunnyInstances.ps1') -ConfigPath (Join-Path $r 'server-instance.json') -Apply -RestartChangedStacks:(-not$nr) -SkipHttpProbe:$skip} -ArgumentList $infraRoot,[bool]$NoRestart,[bool]$SkipHttpProbe
  }
  Write-Host "FLEET_APPLY_PASS name=$($s.name) host=$($s.publicHost)"
}
if(-not$Apply){Write-Host "FLEET_APPLY_VALIDATE_ONLY=PASS nodes=$($servers.Count)"}else{Write-Host "FLEET_APPLY_ALL=PASS nodes=$($servers.Count)"}
