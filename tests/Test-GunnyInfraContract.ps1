$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$required=@('Apply-AllGunnyInstances.ps1','Set-GunnyPublicHost.ps1','Sync-GunnyInfraFleet.ps1','Invoke-GunnyFleet.ps1','Deploy-GunnyFleet.ps1','server-instance.example.json','fleet.example.json','lib\Apply-GunnyV389Instance.ps1','lib\Get-GunnyV389Instance.ps1','lib\Apply-DDTank30Instance.ps1','lib\Get-DDTank30Instance.ps1','lib\Stop-DDTank30Supervisor.ps1')
foreach($rel in $required){if(-not(Test-Path (Join-Path $root $rel))){throw "Missing infra artifact: $rel"}}
foreach($f in Get-ChildItem $root -File -Recurse -Filter '*.ps1'){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e);if($e.Count){throw "PowerShell syntax error in $($f.FullName): $($e[0].Message)"}}
$active=@('Apply-AllGunnyInstances.ps1','Set-GunnyPublicHost.ps1','Sync-GunnyInfraFleet.ps1','Invoke-GunnyFleet.ps1','Deploy-GunnyFleet.ps1')
foreach($rel in $active){$raw=Get-Content (Join-Path $root $rel)-Raw;if($raw -match '_recover'){throw "$rel depends on a recovery worktree"};if($raw -match '(?<!\d)103\.9\.156\.(181|182)(?!\d)'){throw "$rel hard-codes a production IP"}}
$example=Get-Content (Join-Path $root 'server-instance.example.json')-Raw|ConvertFrom-Json
if([string]$example.publicHost -notmatch '^203\.0\.113\.'){throw 'Example manifest must use TEST-NET-3.'}
$fleet=Get-Content (Join-Path $root 'fleet.example.json')-Raw|ConvertFrom-Json
if(@($fleet.servers).Count-lt3){throw 'Fleet example must cover multiple nodes.'}
$deploy=Join-Path $root 'Deploy-GunnyFleet.ps1'
$inventory=Join-Path $root 'fleet.example.json'
$out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deploy -InventoryPath $inventory 2>&1 | Out-String
if($LASTEXITCODE-ne0){throw "Fleet dry-run exited ${LASTEXITCODE}:`n$out"}
if($out -notmatch 'FLEET_SYNC_VALIDATE_ONLY=PASS nodes=3' -or $out -notmatch 'FLEET_APPLY_VALIDATE_ONLY=PASS nodes=3' -or $out -notmatch 'GUNNY_FLEET_VALIDATE_ONLY=PASS'){throw "Fleet dry-run contract failed:`n$out"}
Write-Host 'GUNNY_INFRA_CONTRACT=PASS'