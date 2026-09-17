[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$SkipSourceConfig,
    [switch]$ApplyRuntime,
    [switch]$ApplyDatabase,
    [switch]$ApplyIis
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-DDTank30Instance.ps1')
$instance = Get-DDTank30Instance -ConfigPath $ConfigPath
$utf8 = New-Object Text.UTF8Encoding($false)

function Set-AppSettingValue([string]$Path,[string]$Key,[string]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(<add\s+key="' + [regex]::Escape($Key) + '"\s+value=")[^"]*(")'
    $matches = [regex]::Matches($raw,$pattern)
    if ($matches.Count -ne 1) { throw "Expected exactly one appSetting '$Key' in $Path, found $($matches.Count)." }
    $encoded = [Security.SecurityElement]::Escape($Value)
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $encoded + $m.Groups[2].Value }
    $updated = [regex]::Replace($raw,$pattern,$evaluator,1)
    [IO.File]::WriteAllText($Path,$updated,$utf8)
}

function Set-DDTank30ConfigSet([string]$Root,[switch]$RuntimeLayout) {
    if ($RuntimeLayout) {
        $game = Join-Path $Root 'game\Road.Service.exe.config'
        $center = Join-Path $Root 'center\Center.Service.exe.config'
        $fight = Join-Path $Root 'fighting\Fighting.Service.exe.config'
    } else {
        $game = Join-Path $Root 'Game.Service\App.config'
        $center = Join-Path $Root 'Center.Service\App.config'
        $fight = Join-Path $Root 'Fighting.Service\App.config'
    }
    Set-AppSettingValue $game 'IP' $instance.PublicHost
    Set-AppSettingValue $game 'Port' ([string]$instance.RoadPort)
    Set-AppSettingValue $game 'LoginServerIp' $instance.CenterHost
    Set-AppSettingValue $game 'LoginServerPort' ([string]$instance.CenterPort)
    Set-AppSettingValue $game 'FightServerIp' $instance.FightHost
    Set-AppSettingValue $game 'FightServerPort' ([string]$instance.FightPort)
    Set-AppSettingValue $center 'IP' $instance.CenterHost
    Set-AppSettingValue $center 'Port' ([string]$instance.CenterPort)
    $fightKey = if ([IO.File]::ReadAllText($fight) -match '<add\s+key="Ip"') { 'Ip' } else { 'IP' }
    Set-AppSettingValue $fight $fightKey $instance.FightHost
    Set-AppSettingValue $fight 'Port' ([string]$instance.FightPort)
}

function Set-RequestWebConfig([string]$Path) {
    $base = "http://$($instance.PublicHost):$($instance.WebPort)"
    $values = @{
        ExitURL = "$base/"
        ExitURL_a = "$base/?username={0}&site={1}"
        ExitURL_b = "$base/?username={0}&site={1}"
        PayURL = "$base/"
        PayURL_a = "$base/"
        PayURL_51wan = "$base/"
        FavoriteUrl = "$base/"
        FavoriteUrl_a = "$base/?username={0}&site={1}"
        FavoriteUrl_b = "$base/?username={0}&site={1}"
        LoginUrl = "$base/"
        FriendInterface = "$base/Request/IMFriendsBbs.ashx?uid={0}"
    }
    foreach ($key in $values.Keys) { Set-AppSettingValue $Path $key $values[$key] }
}

if (-not $SkipSourceConfig) {
    Set-DDTank30ConfigSet -Root $RepoRoot
    foreach ($rel in @('Tank.Request\Web.config','Tank.Request\Tank.Request\Web.config')) {
        $path = Join-Path $RepoRoot $rel
        if (Test-Path -LiteralPath $path) { Set-RequestWebConfig $path }
    }
}

if ($ApplyRuntime) {
    $runtime = Join-Path $instance.Root 'runtime'
    Set-DDTank30ConfigSet -Root $runtime -RuntimeLayout
    $runtimeRequest = Join-Path $instance.Root 'webapps\Request\Web.config'
    if (Test-Path -LiteralPath $runtimeRequest) { Set-RequestWebConfig $runtimeRequest }
}

if ($ApplyDatabase) {
    $cn = New-Object Data.SqlClient.SqlConnection 'Data Source=.\SQLEXPRESS;Initial Catalog=Db_Tank_V30;Integrated Security=True'
    $cn.Open()
    try {
        foreach ($id in $instance.DatabaseServerIds) {
            $cmd = $cn.CreateCommand()
            $cmd.CommandText = 'UPDATE Server_List SET IP=@ip' + $(if ($id -eq $instance.DatabaseServerIds[0]) { ', Port=@port' } else { '' }) + ' WHERE ID=@id'
            [void]$cmd.Parameters.Add('@ip',[Data.SqlDbType]::VarChar,64); $cmd.Parameters['@ip'].Value=$instance.PublicHost
            [void]$cmd.Parameters.Add('@id',[Data.SqlDbType]::Int); $cmd.Parameters['@id'].Value=$id
            if ($id -eq $instance.DatabaseServerIds[0]) { [void]$cmd.Parameters.Add('@port',[Data.SqlDbType]::Int); $cmd.Parameters['@port'].Value=$instance.RoadPort }
            if ($cmd.ExecuteNonQuery() -ne 1) { throw "DDTank30 Server_List row $id was not updated exactly once." }
        }
    } finally { $cn.Close() }
}

if ($ApplyIis) {
    Import-Module WebAdministration
    $site = $instance.WebSite
    if (-not (Test-Path "IIS:\Sites\$site")) { throw "IIS site not found: $site" }
    $wanted = "$($instance.PublicHost):$($instance.WebPort):"
    $bindings = @(Get-WebBinding -Name $site -Protocol http)
    foreach ($binding in $bindings) {
        if ($binding.bindingInformation -ne $wanted) { Remove-WebBinding -Name $site -Protocol http -BindingInformation $binding.bindingInformation }
    }
    if (-not (Get-WebBinding -Name $site -Protocol http | Where-Object {$_.bindingInformation -eq $wanted})) {
        New-WebBinding -Name $site -Protocol http -IPAddress $instance.PublicHost -Port $instance.WebPort | Out-Null
    }
}

Write-Host "DDTANK30_INSTANCE_APPLY=PASS host=$($instance.PublicHost) web=$($instance.WebPort) game=$($instance.RoadPort) config=$($instance.ConfigPath)"