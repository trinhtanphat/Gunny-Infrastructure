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

# Contract checks after generation. Host is centralized; legacy ports remain edition-specific.
[xml]$road=Get-Content (Join-Path $TargetRoot 'SERVER\Road\Road.Service.exe.config') -Raw
$rs=@{};foreach($n in $road.configuration.appSettings.add){$rs[[string]$n.key]=[string]$n.value}
foreach($pair in @(@('IP',$instance.PublicHost),@('Port',[string]$instance.RoadPort),@('LoginServerIp',$instance.PublicHost),@('LoginServerPort',[string]$instance.CenterPort),@('FightServerIp',$instance.PublicHost),@('FightServerPort',[string]$instance.FightPort))){if($rs[$pair[0]]-ne$pair[1]){throw "Road contract mismatch $($pair[0])=$($rs[$pair[0]]) expected $($pair[1])"}}
[xml]$center=Get-Content (Join-Path $TargetRoot 'SERVER\center\Center.Service.exe.config') -Raw;$cs=@{};foreach($n in $center.configuration.appSettings.add){$cs[[string]$n.key]=[string]$n.value};if($cs.IP-ne$instance.PublicHost-or$cs.Port-ne[string]$instance.CenterPort){throw 'Center endpoint contract mismatch.'}
[xml]$fight=Get-Content (Join-Path $TargetRoot 'SERVER\Fight\Fighting.Service.exe.config') -Raw;$fs=@{};foreach($n in $fight.configuration.appSettings.add){$fs[[string]$n.key]=[string]$n.value};if($fs.IP-ne$instance.PublicHost-or$fs.Port-ne[string]$instance.FightPort){throw 'Fight endpoint contract mismatch.'}
[xml]$client=Get-Content (Join-Path $TargetRoot 'gunny\config.xml') -Raw;$versions=@($client.SelectNodes('//version'));$max=($versions|ForEach-Object{[int]$_.to}|Measure-Object -Maximum).Maximum;if($max-ne389){throw "Expected Gunny v389 client chain, got max version $max"}

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
Write-Host "GUNNY_V389_INSTANCE_APPLY=PASS old=$oldHost new=$($instance.PublicHost) replacements=$total client=v389 config=$($instance.ConfigPath)"