[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PublicHost,
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'server-instance.json'),
    [switch]$NoRestart,
    [switch]$SkipHttpProbe
)
$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $ConfigPath)){throw "Instance config missing: $ConfigPath"}
$localIps=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Select-Object -ExpandProperty IPAddress)
if($localIps -notcontains $PublicHost){throw "PublicHost $PublicHost is not assigned to this server. Configure the NIC first."}
$cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$old=[string]$cfg.publicHost
$backupDir=Join-Path $PSScriptRoot 'manifest-backups';New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
$backup=Join-Path $backupDir ('server-instance-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')
Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
$cfg.publicHost=$PublicHost
[IO.File]::WriteAllText($ConfigPath,($cfg|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Host "PUBLIC_HOST_UPDATED old=$old new=$PublicHost manifestBackup=$backup"
$apply=Join-Path $PSScriptRoot 'Apply-AllGunnyInstances.ps1'
& $apply -ConfigPath $ConfigPath -Apply -RestartChangedStacks:(-not $NoRestart) -SkipHttpProbe:$SkipHttpProbe
