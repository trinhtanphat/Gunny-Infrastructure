[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\Gunny-Infra\server-instance.json',
    [switch]$Apply,
    [bool]$RestartChangedStacks = $true,
    [switch]$SkipHttpProbe
)
$ErrorActionPreference='Stop'

function Read-AppSetting([string]$Path,[string]$Key) {
    [xml]$x=Get-Content -LiteralPath $Path -Raw
    $n=@($x.configuration.appSettings.add|Where-Object{$_.key-eq$Key})[0]
    if(-not$n){throw "Missing appSetting $Key in $Path"}
    [string]$n.value
}
function Copy-BackupFile([string]$Root,[string]$Relative,[string]$BackupRoot,[string]$Prefix) {
    $src=Join-Path $Root $Relative
    if(-not(Test-Path -LiteralPath $src)){throw "Backup source missing: $src"}
    $dst=Join-Path $BackupRoot (Join-Path $Prefix $Relative)
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent)|Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
function Get-ServerRows([string]$ConnectionString,[int[]]$Ids) {
    if(-not$Ids -or $Ids.Count-eq0){return @()}
    $cn=New-Object Data.SqlClient.SqlConnection $ConnectionString;$cn.Open()
    try {
        $cmd=$cn.CreateCommand();$cmd.CommandText='SELECT ID,Name,IP,Port,State,Online FROM Server_List WHERE ID IN ('+($Ids -join ',')+') ORDER BY ID'
        $r=$cmd.ExecuteReader();$rows=@()
        while($r.Read()){$rows+=[pscustomobject]@{ID=[int]$r['ID'];Name=[string]$r['Name'];IP=[string]$r['IP'];Port=[int]$r['Port'];State=[int]$r['State'];Online=[int]$r['Online']}}
        $r.Close();$rows
    } finally {$cn.Close()}
}
function Wait-Listener([string]$Address,[int]$Port,[int]$Seconds=150) {
    $end=(Get-Date).AddSeconds($Seconds)
    do {
        $hit=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|Where-Object{$_.LocalPort-eq$Port -and ($_.LocalAddress-eq$Address -or $_.LocalAddress-eq'0.0.0.0')})
        if($hit.Count-gt0){return $hit[0]}
        Start-Sleep -Milliseconds 500
    } while((Get-Date)-lt$end)
    throw "Listener not ready: $Address`:$Port"
}
function Assert-Http200([string]$Uri) {
    $r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
    if([int]$r.StatusCode-ne200){throw "HTTP probe expected 200: $Uri got $($r.StatusCode)"}
    Write-Host "HTTP_200 $Uri"
}

if(-not(Test-Path -LiteralPath $ConfigPath)){throw "Instance config missing: $ConfigPath"}
$cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
if(-not$cfg.publicHost -or -not$cfg.legacyV389 -or -not$cfg.ddtank30){throw 'Instance config requires publicHost, legacyV389 and ddtank30.'}
$publicHost=[string]$cfg.publicHost
$v=$cfg.legacyV389;$d=$cfg.ddtank30
$localIps=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Select-Object -ExpandProperty IPAddress)
if($localIps -notcontains $publicHost){throw "publicHost $publicHost is not assigned to this server. Configure the NIC first."}

$vRoot=[string]$v.root;$dRoot=[string]$d.root
$vApply=Join-Path $PSScriptRoot 'lib\Apply-GunnyV389Instance.ps1'
$dApply=Join-Path $PSScriptRoot 'lib\Apply-DDTank30Instance.ps1'
foreach($tool in @($vApply,$dApply)){if(-not(Test-Path -LiteralPath $tool)){throw "Apply tool missing: $tool"}}
$vWeb=Join-Path $vRoot 'gunny\Web.config'
$dRoad=Join-Path $dRoot 'runtime\game\Road.Service.exe.config'
$oldV=Read-AppSetting $vWeb 'ActiveIP';$oldD=Read-AppSetting $dRoad 'IP'
$vChanged=$oldV-ne$publicHost;$dChanged=$oldD-ne$publicHost
Write-Host "INSTANCE_PLAN host=$publicHost v389:$oldV->$publicHost ddtank30:$oldD->$publicHost apply=$Apply restartChanged=$RestartChangedStacks"
if(-not$Apply){Write-Host 'INSTANCE_VALIDATE_ONLY=PASS';return}

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot=Join-Path (Join-Path $PSScriptRoot 'backups') $stamp
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupRoot 'server-instance.json') -Force
$vRequiredFiles=@('AdminGunny\Web.config','SERVER\Fight\Fighting.Service.exe.config','SERVER\Road\Road.Service.exe.config','SERVER\Road\battle.xml','SERVER\center\Center.Service.exe.config','gunny\Web.config','gunny\config.xml','request\Web.config')
$vOptionalFiles=@('SERVER\Road\Road.Service.vshost.exe.config','htdocs\Config.php','index.html')
foreach($rel in $vRequiredFiles){Copy-BackupFile $vRoot $rel $backupRoot 'v389'}
foreach($rel in $vOptionalFiles){if(Test-Path -LiteralPath (Join-Path $vRoot $rel)){Copy-BackupFile $vRoot $rel $backupRoot 'v389'}}
$dFiles=@('runtime\game\Road.Service.exe.config','runtime\center\Center.Service.exe.config','runtime\fighting\Fighting.Service.exe.config','webapps\Request\Web.config')
foreach($rel in $dFiles){Copy-BackupFile $dRoot $rel $backupRoot 'ddtank30'}
$vCon=Read-AppSetting (Join-Path $vRoot 'SERVER\Road\Road.Service.exe.config') 'conString'
$vRows=Get-ServerRows $vCon @($v.databaseServerIds|ForEach-Object{[int]$_})
$dRows=Get-ServerRows 'Data Source=.\SQLEXPRESS;Initial Catalog=Db_Tank_V30;Integrated Security=True' @($d.databaseServerIds|ForEach-Object{[int]$_})
Import-Module WebAdministration
$snapshot=[ordered]@{timestamp=(Get-Date).ToString('o');publicHost=$publicHost;oldV389Host=$oldV;oldDdtank30Host=$oldD;v389Rows=$vRows;ddtank30Rows=$dRows;v389Bindings=@(Get-WebBinding -Name ([string]$v.webSite) -Protocol http|ForEach-Object{$_.bindingInformation});ddtank30Bindings=@(Get-WebBinding -Name ([string]$d.webSite) -Protocol http|ForEach-Object{$_.bindingInformation})}
[IO.File]::WriteAllText((Join-Path $backupRoot 'snapshot.json'),($snapshot|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'last-backup.txt'),$backupRoot,(New-Object Text.UTF8Encoding($false)))
Write-Host "BACKUP_READY=$backupRoot"

& $vApply -ConfigPath $ConfigPath -TargetRoot $vRoot -ApplyDatabase -ApplyIis
& $dApply -ConfigPath $ConfigPath -RepoRoot (Join-Path $dRoot 'repo') -SkipSourceConfig -ApplyRuntime -ApplyDatabase -ApplyIis

if($vChanged -and $RestartChangedStacks){
    $restart=Join-Path $vRoot 'ops\Start-GunnyServer.ps1'
    if(-not(Test-Path $restart)){throw "v389 restart tool missing: $restart"}
    & $restart -Restart -TimeoutSeconds 120
}
if($dChanged -and $RestartChangedStacks){
    $stop=Join-Path $PSScriptRoot 'lib\Stop-DDTank30Supervisor.ps1'
    & $stop
    Start-ScheduledTask -TaskName 'DDTank30-Stack'
}
if(($vChanged-or$dChanged)-and-not$RestartChangedStacks){Write-Warning 'Host changed but restart was disabled; processes still need restart before listeners use the new host.'}

if((Read-AppSetting $vWeb 'ActiveIP')-ne$publicHost){throw 'v389 ActiveIP post-apply mismatch.'}
if((Read-AppSetting $dRoad 'IP')-ne$publicHost){throw 'DDTank30 runtime IP post-apply mismatch.'}
$vRowsAfter=Get-ServerRows $vCon @($v.databaseServerIds|ForEach-Object{[int]$_})
foreach($row in $vRowsAfter){if($row.IP-ne$publicHost){throw "v389 Server_List ID=$($row.ID) host mismatch: $($row.IP)"}}
if($vRowsAfter.Count-gt0 -and $vRowsAfter[0].Port-ne[int]$v.roadPort){throw 'v389 primary Server_List port mismatch.'}
$dRowsAfter=Get-ServerRows 'Data Source=.\SQLEXPRESS;Initial Catalog=Db_Tank_V30;Integrated Security=True' @($d.databaseServerIds|ForEach-Object{[int]$_})
foreach($row in $dRowsAfter){if($row.IP-ne$publicHost){throw "DDTank30 Server_List ID=$($row.ID) host mismatch: $($row.IP)"}}
if($dRowsAfter.Count-gt0 -and $dRowsAfter[0].Port-ne[int]$d.roadPort){throw 'DDTank30 primary Server_List port mismatch.'}
$vBindings=@(Get-WebBinding -Name ([string]$v.webSite) -Protocol http|ForEach-Object{$_.bindingInformation})
if($vBindings -notcontains "*:$([int]$v.webPort):" -and $vBindings -notcontains "$publicHost`:$([int]$v.webPort):"){throw 'v389 IIS binding mismatch.'}
$dWanted="$publicHost`:$([int]$d.webPort):"
$dBindings=@(Get-WebBinding -Name ([string]$d.webSite) -Protocol http|ForEach-Object{$_.bindingInformation})
if($dBindings -notcontains $dWanted){throw "DDTank30 IIS binding mismatch; expected $dWanted"}

$canVerifyListeners=(-not($vChanged-or$dChanged))-or$RestartChangedStacks
if($canVerifyListeners){
    [void](Wait-Listener $publicHost ([int]$v.roadPort));[void](Wait-Listener $publicHost ([int]$v.centerPort));[void](Wait-Listener $publicHost ([int]$v.fightPort))
    [void](Wait-Listener $publicHost ([int]$d.roadPort));[void](Wait-Listener ([string]$d.centerHost) ([int]$d.centerPort));[void](Wait-Listener ([string]$d.fightHost) ([int]$d.fightPort))
    Write-Host 'LISTENER_CONTRACT=PASS'
}
if(-not$SkipHttpProbe){
    Assert-Http200 "http://$publicHost/Gunny/login.htm"
    Assert-Http200 "http://$publicHost/Gunny/config.xml"
    Assert-Http200 "http://$publicHost`:$([int]$d.webPort)/"
    Assert-Http200 "http://$publicHost`:$([int]$d.webPort)/Request/CreateLogin.aspx"
}
[xml]$client=Get-Content (Join-Path $vRoot 'gunny\config.xml') -Raw
$maxVersion=(@($client.SelectNodes('//version'))|ForEach-Object{[int]$_.to}|Measure-Object -Maximum).Maximum
if($maxVersion-ne389){throw "Legacy client version drifted; expected v389, got $maxVersion"}
Write-Host "ALL_GUNNY_INSTANCE_APPLY=PASS host=$publicHost v389=v389 ddtank30=3.0 backup=$backupRoot"
