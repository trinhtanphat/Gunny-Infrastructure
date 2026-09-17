[CmdletBinding()]
param(
  [string]$InventoryPath=(Join-Path $PSScriptRoot 'fleet.json'),
  [string]$TemplatePath=(Join-Path $PSScriptRoot 'server-instance.example.json'),
  [switch]$Apply,
  [PSCredential]$Credential
)
$ErrorActionPreference='Stop'
foreach($p in @($InventoryPath,$TemplatePath)){if(-not(Test-Path -LiteralPath $p)){throw "Missing file: $p"}}
$inventory=Get-Content $InventoryPath -Raw|ConvertFrom-Json
$template=Get-Content $TemplatePath -Raw|ConvertFrom-Json
$servers=@($inventory.servers|Where-Object{$_.enabled})
if($servers.Count-eq0){throw 'Fleet inventory has no enabled servers.'}
$names=@{};$hosts=@{}
foreach($s in $servers){
  foreach($field in @('name','computerName','publicHost')){if([string]::IsNullOrWhiteSpace([string]$s.$field)){throw "Fleet server missing $field."}}
  if($names.ContainsKey([string]$s.name)){throw "Duplicate fleet name: $($s.name)"};$names[[string]$s.name]=$true
  if($hosts.ContainsKey([string]$s.publicHost)){throw "Duplicate publicHost: $($s.publicHost)"};$hosts[[string]$s.publicHost]=$true
}
$bundleFiles=@('Apply-AllGunnyInstances.ps1','Set-GunnyPublicHost.ps1','README.md','server-instance.example.json')
foreach($name in $bundleFiles){if(-not(Test-Path (Join-Path $PSScriptRoot $name))){throw "Bundle file missing: $name"}}
foreach($dirName in @('lib','resources')){if(-not(Test-Path (Join-Path $PSScriptRoot $dirName))){throw "Bundle directory missing: $dirName"}}
foreach($s in $servers){
  $infraRoot=if($s.infraRoot){[string]$s.infraRoot}else{'C:\Gunny-Infra'}
  Write-Host "FLEET_SYNC_PLAN name=$($s.name) computer=$($s.computerName) host=$($s.publicHost) root=$infraRoot apply=$Apply"
  if(-not$Apply){continue}
  $cfg=Get-Content $TemplatePath -Raw|ConvertFrom-Json;$cfg.publicHost=[string]$s.publicHost
  $tmp=Join-Path $env:TEMP ("gunny-instance-$([guid]::NewGuid().ToString('N')).json")
  [IO.File]::WriteAllText($tmp,($cfg|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
  $session=$null
  try{
    $local=([string]$s.computerName -in @('.', 'localhost', [Environment]::MachineName, $env:COMPUTERNAME))
    if($local){
      New-Item -ItemType Directory -Force -Path $infraRoot,(Join-Path $infraRoot 'lib'),(Join-Path $infraRoot 'resources')|Out-Null
      $sameRoot=([IO.Path]::GetFullPath($infraRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'))
      if(-not $sameRoot){
        foreach($name in $bundleFiles){Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $infraRoot $name) -Force}
        Copy-Item (Join-Path $PSScriptRoot 'lib\*') (Join-Path $infraRoot 'lib') -Force
        Copy-Item (Join-Path $PSScriptRoot 'resources\*') (Join-Path $infraRoot 'resources') -Force
      }
      Copy-Item $tmp (Join-Path $infraRoot 'server-instance.json') -Force
    } else {
      $args=@{ComputerName=[string]$s.computerName;ErrorAction='Stop'};if($Credential){$args.Credential=$Credential}
      $session=New-PSSession @args
      Invoke-Command -Session $session -ScriptBlock {param($r) New-Item -ItemType Directory -Force -Path $r,(Join-Path $r 'lib'),(Join-Path $r 'resources')|Out-Null} -ArgumentList $infraRoot
      foreach($name in $bundleFiles){Copy-Item (Join-Path $PSScriptRoot $name) -Destination (Join-Path $infraRoot $name) -ToSession $session -Force}
      Copy-Item (Join-Path $PSScriptRoot 'lib\*') -Destination (Join-Path $infraRoot 'lib') -ToSession $session -Force
      Copy-Item (Join-Path $PSScriptRoot 'resources\*') -Destination (Join-Path $infraRoot 'resources') -ToSession $session -Force
      Copy-Item $tmp -Destination (Join-Path $infraRoot 'server-instance.json') -ToSession $session -Force
    }
    Write-Host "FLEET_SYNC_PASS name=$($s.name) host=$($s.publicHost)"
  } finally {if($session){Remove-PSSession $session};Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
if(-not$Apply){Write-Host "FLEET_SYNC_VALIDATE_ONLY=PASS nodes=$($servers.Count)"}else{Write-Host "FLEET_SYNC_ALL=PASS nodes=$($servers.Count)"}
