[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TargetRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$ApplyDatabase,
    [switch]$ApplyIis
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Get-GunnyV389Instance.ps1')
$instance=Get-GunnyV389Instance -ConfigPath $ConfigPath

function Get-ActiveIp([string]$Root){
    $path=Join-Path $Root 'gunny\Web.config'
    [xml]$x=Get-Content -LiteralPath $path -Raw
    $n=@($x.configuration.appSettings.add|Where-Object{$_.key-eq'ActiveIP'})[0]
    if(-not$n){throw "ActiveIP appSetting missing: $path"}
    return [string]$n.value
}

function Replace-AsciiIpToken([string]$Path,[string]$Old,[string]$New){
    if(-not(Test-Path -LiteralPath $Path)){throw "Managed endpoint file missing: $Path"}
    if($Old-eq$New){return 0}
    $src=[IO.File]::ReadAllBytes($Path);$oldBytes=[Text.Encoding]::ASCII.GetBytes($Old);$newBytes=[Text.Encoding]::ASCII.GetBytes($New)
    $ms=New-Object IO.MemoryStream;$count=0;$i=0
    while($i-lt$src.Length){
        $match=$false
        if($i+$oldBytes.Length-le$src.Length){
            $match=$true
            for($j=0;$j-lt$oldBytes.Length;$j++){if($src[$i+$j]-ne$oldBytes[$j]){$match=$false;break}}
            if($match){
                $before=if($i-gt0){$src[$i-1]}else{[byte]0}
                $afterIndex=$i+$oldBytes.Length;$after=if($afterIndex-lt$src.Length){$src[$afterIndex]}else{[byte]0}
                $beforeDigit=($before-ge48-and$before-le57);$afterDigit=($after-ge48-and$after-le57)
                if($beforeDigit-or$afterDigit){$match=$false}
            }
        }
        if($match){$ms.Write($newBytes,0,$newBytes.Length);$i+=$oldBytes.Length;$count++}
        else{$ms.WriteByte($src[$i]);$i++}
    }
    if($count-gt0){[IO.File]::WriteAllBytes($Path,$ms.ToArray())}
    $ms.Dispose();return $count
}

function Set-AppSettingValue([string]$Path,[string]$Key,[string]$Value){
    [xml]$x=Get-Content -LiteralPath $Path -Raw
    $n=@($x.configuration.appSettings.add|Where-Object{$_.key-eq$Key})[0]
    if(-not$n){throw "Missing appSetting $Key in $Path"}
    $n.value=$Value
    $x.Save($Path)
}
function Set-EndpointAddressByName([string]$Path,[string]$Name,[string]$Address){
    [xml]$x=Get-Content -LiteralPath $Path -Raw
    $n=@($x.configuration.'system.serviceModel'.client.endpoint|Where-Object{$_.name-eq$Name})[0]
    if(-not$n){throw "Missing endpoint $Name in $Path"}
    $n.address=$Address
    $x.Save($Path)
}
function Set-CenterServiceAddresses([string]$Path,[string]$ServiceHost,[int]$HttpPort,[int]$TcpPort){
    [xml]$x=Get-Content -LiteralPath $Path -Raw
    $svc=@($x.configuration.'system.serviceModel'.services.service|Where-Object{$_.name-eq'Center.Server.CenterService'})[0]
    if(-not$svc){throw "Center service node missing in $Path"}
    $base=@($svc.host.baseAddresses.add)[0]
    $ep=@($svc.endpoint|Where-Object{$_.contract-eq'Center.Server.ICenterService'})[0]
    if(-not$base -or -not$ep){throw "Center service addresses missing in $Path"}
    $base.baseAddress=("http://{0}:{1}/CenterService/" -f $ServiceHost,$HttpPort)
    $ep.address=("net.tcp://{0}:{1}/" -f $ServiceHost,$TcpPort)
    $x.Save($Path)
}
function Set-BattleFightHost([string]$Path,[string]$FightHost,[int]$Port){
    [xml]$x=Get-Content -LiteralPath $Path -Raw
    $n=@($x.list.server|Where-Object{[int]$_.port-eq$Port})[0]
    if(-not$n){throw "Battle fight endpoint port $Port missing in $Path"}
    $n.ip=$FightHost
    $x.Save($Path)
}
$oldHost=Get-ActiveIp $TargetRoot
$requiredManaged=@(
 'AdminGunny\Web.config',
 'SERVER\Fight\Fighting.Service.exe.config',
 'SERVER\Road\Road.Service.exe.config',
 'SERVER\Road\battle.xml',
 'SERVER\center\Center.Service.exe.config',
 'gunny\Web.config',
 'gunny\config.xml',
 'request\Web.config'
)
$optionalManaged=@(
 'SERVER\Road\Road.Service.vshost.exe.config',
 'htdocs\Config.php',
 'index.html'
)
$total=0
foreach($rel in $requiredManaged){$total+=Replace-AsciiIpToken (Join-Path $TargetRoot $rel) $oldHost $instance.PublicHost}
foreach($rel in $optionalManaged){$path=Join-Path $TargetRoot $rel;if(Test-Path -LiteralPath $path){$total+=Replace-AsciiIpToken $path $oldHost $instance.PublicHost}}

# Runtime/internal traffic is always loopback. PublicHost is only for client-facing URLs/DB/IIS.
$vRoad=Join-Path $TargetRoot 'SERVER\Road\Road.Service.exe.config'
$vCenter=Join-Path $TargetRoot 'SERVER\center\Center.Service.exe.config'
$vFight=Join-Path $TargetRoot 'SERVER\Fight\Fighting.Service.exe.config'
$vBattle=Join-Path $TargetRoot 'SERVER\Road\battle.xml'
$vRequest=Join-Path $TargetRoot 'request\Web.config'
$vAdmin=Join-Path $TargetRoot 'AdminGunny\Web.config'
Set-AppSettingValue $vRoad 'IP' $instance.InternalHost
Set-AppSettingValue $vRoad 'LoginServerIp' $instance.InternalHost
Set-AppSettingValue $vRoad 'FightServerIp' $instance.InternalHost
Set-AppSettingValue $vCenter 'IP' $instance.InternalHost
Set-AppSettingValue $vFight 'IP' $instance.InternalHost
Set-BattleFightHost $vBattle $instance.InternalHost $instance.FightPort
Set-EndpointAddressByName $vRoad 'NetTcpBinding_ICenterService' ("net.tcp://{0}:{1}/" -f $instance.InternalHost,$instance.CenterWcfTcpPort)
Set-EndpointAddressByName $vRoad 'PassPortSoap' ("http://{0}/AdminGunny/Flash_Port/PassPort.asmx" -f $instance.InternalHost)
Set-CenterServiceAddresses $vCenter $instance.InternalHost $instance.CenterWcfHttpPort $instance.CenterWcfTcpPort
Set-EndpointAddressByName $vRequest 'NetTcpBinding_ICenterService' ("net.tcp://{0}:{1}/" -f $instance.InternalHost,$instance.CenterWcfTcpPort)
Set-EndpointAddressByName $vAdmin 'NetTcpBinding_ICenterService' ("net.tcp://{0}:{1}/" -f $instance.InternalHost,$instance.CenterWcfTcpPort)
Set-AppSettingValue $vAdmin 'ServerIP' $instance.InternalHost
# Contract checks after generation. Host is centralized; legacy ports remain edition-specific.
[xml]$road=Get-Content (Join-Path $TargetRoot 'SERVER\Road\Road.Service.exe.config') -Raw
$rs=@{};foreach($n in $road.configuration.appSettings.add){$rs[[string]$n.key]=[string]$n.value}
foreach($pair in @(@('IP',$instance.InternalHost),@('Port',[string]$instance.RoadPort),@('LoginServerIp',$instance.InternalHost),@('LoginServerPort',[string]$instance.CenterPort),@('FightServerIp',$instance.InternalHost),@('FightServerPort',[string]$instance.FightPort))){if($rs[$pair[0]]-ne$pair[1]){throw "Road contract mismatch $($pair[0])=$($rs[$pair[0]]) expected $($pair[1])"}}
[xml]$center=Get-Content (Join-Path $TargetRoot 'SERVER\center\Center.Service.exe.config') -Raw;$cs=@{};foreach($n in $center.configuration.appSettings.add){$cs[[string]$n.key]=[string]$n.value};if($cs.IP-ne$instance.InternalHost-or$cs.Port-ne[string]$instance.CenterPort){throw 'Center endpoint contract mismatch.'}
[xml]$fight=Get-Content (Join-Path $TargetRoot 'SERVER\Fight\Fighting.Service.exe.config') -Raw;$fs=@{};foreach($n in $fight.configuration.appSettings.add){$fs[[string]$n.key]=[string]$n.value};if($fs.IP-ne$instance.InternalHost-or$fs.Port-ne[string]$instance.FightPort){throw 'Fight endpoint contract mismatch.'}
[xml]$client=Get-Content (Join-Path $TargetRoot 'gunny\config.xml') -Raw;$versions=@($client.SelectNodes('//version'));$max=($versions|ForEach-Object{[int]$_.to}|Measure-Object -Maximum).Maximum;if($max-lt389){throw "Expected Gunny v389-compatible client chain with max version >= 389, got $max"}

if($ApplyDatabase){
    [xml]$runtimeRoad=Get-Content (Join-Path $TargetRoot 'SERVER\Road\Road.Service.exe.config') -Raw
    $csNode=@($runtimeRoad.configuration.appSettings.add|Where-Object{$_.key-eq'conString'})[0]
    if(-not$csNode){throw 'Road conString is missing.'}
    $cn=New-Object Data.SqlClient.SqlConnection ([string]$csNode.value);$cn.Open()
    try{
        foreach($id in $instance.DatabaseServerIds){
            $cmd=$cn.CreateCommand();$cmd.CommandText='UPDATE Server_List SET IP=@ip WHERE ID=@id';[void]$cmd.Parameters.Add('@ip',[Data.SqlDbType]::VarChar,64);$cmd.Parameters['@ip'].Value=$instance.PublicHost;[void]$cmd.Parameters.Add('@id',[Data.SqlDbType]::Int);$cmd.Parameters['@id'].Value=$id;if($cmd.ExecuteNonQuery()-ne1){throw "Server_List row $id was not updated exactly once."}
        }
        if($instance.DatabaseServerIds.Count-gt0){$cmd=$cn.CreateCommand();$cmd.CommandText='UPDATE Server_List SET Port=@port WHERE ID=@id';[void]$cmd.Parameters.Add('@port',[Data.SqlDbType]::Int);$cmd.Parameters['@port'].Value=$instance.RoadPort;[void]$cmd.Parameters.Add('@id',[Data.SqlDbType]::Int);$cmd.Parameters['@id'].Value=$instance.DatabaseServerIds[0];if($cmd.ExecuteNonQuery()-ne1){throw 'Primary Server_List port update failed.'}}
    }finally{$cn.Close()}
}

if($ApplyIis){
    Import-Module WebAdministration
    if(-not(Test-Path "IIS:\Sites\$($instance.WebSite)")){throw "IIS site missing: $($instance.WebSite)"}
    $bindings=@(Get-WebBinding -Name $instance.WebSite -Protocol http)
    if(-not($bindings|Where-Object{$_.bindingInformation -eq "*:$($instance.WebPort):" -or $_.bindingInformation -eq "$($instance.PublicHost):$($instance.WebPort):"})){throw "IIS site $($instance.WebSite) has no compatible port $($instance.WebPort) binding."}
}
Write-Host "GUNNY_V389_INSTANCE_APPLY=PASS public=$($instance.PublicHost) internal=$($instance.InternalHost) replacements=$total client=v$max config=$($instance.ConfigPath)"