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
$dd30Apply=Get-Content (Join-Path $root 'lib\Apply-DDTank30Instance.ps1') -Raw
foreach($token in @('webroot','Register','admingunny','DDTank30Pool','Get-DDTank30LegacyWebHost')){if($dd30Apply -notmatch [regex]::Escape($token)){throw "DDTank30 bundled apply missing webroot parity token: $token"}}
if($dd30Apply -match '(?<!\d)103\.9\.156\.(181|182)(?!\d)'){throw 'DDTank30 bundled apply hard-codes a production IP'}
foreach($rel in @('lib\Restore-DDTank30WebShellAssets.ps1','resources\ddtank30-webshell-recovery.json')){if(-not(Test-Path (Join-Path $root $rel))){throw "Missing recovery artifact: $rel"}}
$recovery=Get-Content (Join-Path $root 'resources\ddtank30-webshell-recovery.json') -Raw | ConvertFrom-Json
if($recovery.schemaVersion-ne1 -or $recovery.family-ne'DDTank-3.0'){throw 'DDTank30 recovery manifest identity mismatch'}
if(@($recovery.assets).Count-ne9){throw "DDTank30 recovery asset count mismatch: $(@($recovery.assets).Count)"}
foreach($a in $recovery.assets){if([string]$a.sha256 -notmatch '^[0-9A-F]{64}$'){throw "Invalid recovery SHA256: $($a.requestPath)"};if([int64]$a.size-le0){throw "Invalid recovery size: $($a.requestPath)"}}
if(@($recovery.unresolved).requestPath -notcontains '/gunny/images/loop.jpg'){throw 'Recovery manifest must keep loop.jpg explicitly unresolved until an original source is found'}
$resourceArtifacts=@(
  'lib\Ensure-GunnyV389Resources.ps1','lib\Sync-GunnyV389MapAssets.ps1','lib\Sync-GunnyV389MapAudio.ps1','lib\Sync-GunnyV389RuffleRecovery.ps1','lib\Sync-GunnyV389FarmAssets.ps1',
  'lib\v389-map-assets-manifest.tsv','lib\v389-map-audio-manifest.tsv','lib\v389-ruffle-recovery-manifest.tsv','lib\v389-farm-pet-manifest.tsv','resources\gunny-v389-residual-recovery.json'
)
foreach($rel in $resourceArtifacts){if(-not(Test-Path (Join-Path $root $rel))){throw "Missing v389 resource artifact: $rel"}}
$syncRaw=Get-Content (Join-Path $root 'Sync-GunnyInfraFleet.ps1') -Raw
if($syncRaw -notmatch "'resources'"){throw 'Fleet sync must bundle resources directory.'}
$applyRaw=Get-Content (Join-Path $root 'Apply-AllGunnyInstances.ps1') -Raw
if($applyRaw -notmatch 'Ensure-GunnyV389Resources'){throw 'Apply-All must run the v389 resource guard.'}
$guardRaw=Get-Content (Join-Path $root 'lib\Ensure-GunnyV389Resources.ps1') -Raw
foreach($token in @('runtime-v389-map-assets-20260917','runtime-v389-map-audio-20260917','runtime-v389-ruffle-recovery-assets-20260917','gunny-v389-residual-recovery.json','43c21f53343cef61cf91180438bf594b2c8bd51b')){if($guardRaw -notmatch [regex]::Escape($token)){throw "v389 resource guard missing pinned token: $token"}}
$expectedCounts=@{'v389-map-assets-manifest.tsv'=1719;'v389-map-audio-manifest.tsv'=179;'v389-ruffle-recovery-manifest.tsv'=398;'v389-farm-pet-manifest.tsv'=223}
foreach($name in $expectedCounts.Keys){$rows=@(Import-Csv (Join-Path $root ('lib\'+$name)) -Delimiter "`t");if($rows.Count-ne$expectedCounts[$name]){throw "$name row count mismatch: $($rows.Count)"};foreach($row in $rows){if([string]$row.sha256 -notmatch '^[0-9A-F]{64}$' -or [int64]$row.bytes-le0){throw "Invalid resource manifest row in ${name}: $($row.path)"}}}
Write-Host 'GUNNY_INFRA_CONTRACT=PASS'
