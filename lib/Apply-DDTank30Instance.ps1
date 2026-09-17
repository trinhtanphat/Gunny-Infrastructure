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

function Get-AppSettingValue([string]$Path,[string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '<add\s+key="' + [regex]::Escape($Key) + '"\s+value="([^"]*)"'
    $match = [regex]::Match($raw,$pattern)
    if (-not $match.Success) { return $null }
    return [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
}

function Set-AppSettingValueIfPresent([string]$Path,[string]$Key,[string]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(<add\s+key="' + [regex]::Escape($Key) + '"\s+value=")[^"]*(")'
    if ([regex]::IsMatch($raw,$pattern)) { Set-AppSettingValue $Path $Key $Value }
}

function Set-XmlValueAttributeIfPresent([string]$Path,[string]$Element,[string]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(<'+[regex]::Escape($Element)+'\s+value=")[^"]*(")'
    if (-not [regex]::IsMatch($raw,$pattern)) { return }
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $Value + $m.Groups[2].Value }
    $updated = [regex]::Replace($raw,$pattern,$evaluator,1)
    [IO.File]::WriteAllText($Path,$updated,$utf8)
}

function Set-EndpointAddressIfPresent([string]$Path,[string]$Contract,[string]$Address) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $raw = [IO.File]::ReadAllText($Path)
    $pattern = '(<endpoint\b(?=[^>]*\bcontract="' + [regex]::Escape($Contract) + '")[^>]*\baddress=")[^"]*(")'
    if (-not [regex]::IsMatch($raw,$pattern)) { return }
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $Address + $m.Groups[2].Value }
    $updated = [regex]::Replace($raw,$pattern,$evaluator,1)
    [IO.File]::WriteAllText($Path,$updated,$utf8)
}

function Get-DDTank30LegacyWebHost([string]$WebRoot) {
    foreach ($path in @((Join-Path $WebRoot 'gunny\login.htm'),(Join-Path $WebRoot 'gunny\config.xml'))) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $raw = [IO.File]::ReadAllText($path)
        $match = [regex]::Match($raw,'https?://(?<host>\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?/(?:register|reg|Resource|gunny|request)/','IgnoreCase')
        if ($match.Success) { return $match.Groups['host'].Value }
    }
    return $null
}

function Set-LegacyIpListHostIfPresent([string]$Path,[string]$Key,[string]$LegacyHost) {
    if ([string]::IsNullOrWhiteSpace($LegacyHost)) { return }
    $value = Get-AppSettingValue $Path $Key
    if ($null -eq $value) { return }
    $parts = @($value -split '\|' | ForEach-Object {
        if ($_ -eq $LegacyHost -or $_.StartsWith($LegacyHost + '1') -or $_.StartsWith($LegacyHost + '7')) { $instance.PublicHost } else { $_ }
    })
    Set-AppSettingValue $Path $Key ($parts -join '|')
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

function Set-DDTank30WebRoot([string]$WebRoot) {
    if (-not (Test-Path -LiteralPath $WebRoot)) { return }
    $base = "http://$($instance.PublicHost):$($instance.WebPort)"
    $legacyHost = Get-DDTank30LegacyWebHost $WebRoot

    $login = Join-Path $WebRoot 'gunny\login.htm'
    if (Test-Path -LiteralPath $login) {
        $raw = [IO.File]::ReadAllText($login)
        $raw = [regex]::Replace($raw,'href="https?://[^\"]+(?:/reg/forgotpass\.html[^\"]*|/Register/forgotpass\.aspx)"','href="'+$base+'/Register/forgotpass.aspx"','IgnoreCase')
        $raw = [regex]::Replace($raw,'href="https?://[^\"]+/register/"','href="'+$base+'/Register/"','IgnoreCase')
        [IO.File]::WriteAllText($login,$raw,$utf8)
    }

    $config = Join-Path $WebRoot 'gunny\config.xml'
    $xmlValues = @{
        SITE = "$base/Resource/"
        FIRSTPAGE = "$base/gunny/"
        REGISTER = "$base/Register/"
        REQUEST_PATH = "$base/Request/"
        LOGIN_PATH = "$base/gunny/"
        FILL_PATH = "$base/gunny/"
    }
    foreach ($key in $xmlValues.Keys) { Set-XmlValueAttributeIfPresent $config $key $xmlValues[$key] }

    $gunnyWeb = Join-Path $WebRoot 'gunny\Web.config'
    Set-AppSettingValueIfPresent $gunnyWeb 'LoginUrl' "$base/Request/createLogin.aspx"
    Set-AppSettingValueIfPresent $gunnyWeb 'LoginOnUrl' "$base/gunny/login.htm"
    Set-AppSettingValueIfPresent $gunnyWeb 'FlashUrl' "$base/gunny/index.aspx"

    foreach ($rel in @('Request\Web.config','Request\Tank.Request\Web.config')) {
        $request = Join-Path $WebRoot $rel
        if (-not (Test-Path -LiteralPath $request)) { continue }
        Set-RequestWebConfig $request
        Set-LegacyIpListHostIfPresent $request 'AdminIP' $legacyHost
        Set-LegacyIpListHostIfPresent $request 'SentRewardIP' $legacyHost
        Set-EndpointAddressIfPresent $request 'CenterService.ICenterService' "net.tcp://$($instance.CenterHost):$($instance.CenterPort)/"
    }

    $admin = Join-Path $WebRoot 'admingunny\Web.config'
    Set-AppSettingValueIfPresent $admin 'Resource' "$base/Resource/"
    Set-AppSettingValueIfPresent $admin 'ServerIP' $instance.PublicHost
    Set-EndpointAddressIfPresent $admin 'CenterService.ICenterService' "net.tcp://$($instance.CenterHost):$($instance.CenterPort)/"
    Set-EndpointAddressIfPresent $admin 'WebLogin.PassPortSoap' "$base/admingunny/Flash_Port/PassPort.asmx"

    if (-not [string]::IsNullOrWhiteSpace($legacyHost) -and $legacyHost -ne $instance.PublicHost) {
        foreach ($rel in @('gunny\login.htm','gunny\config.xml','gunny\Web.config','Request\Web.config','Request\Tank.Request\Web.config','admingunny\Web.config')) {
            $path = Join-Path $WebRoot $rel
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $raw = [IO.File]::ReadAllText($path)
            if ($raw.Contains($legacyHost)) {
                $raw = $raw.Replace($legacyHost,$instance.PublicHost)
                [IO.File]::WriteAllText($path,$raw,$utf8)
            }
            if ([IO.File]::ReadAllText($path).Contains($legacyHost)) {
                throw "Legacy DDTank30 public host remains in ${path}: $legacyHost"
            }
        }
    }
}

if ($ApplyRuntime) {
    $runtime = Join-Path $instance.Root 'runtime'
    Set-DDTank30ConfigSet -Root $runtime -RuntimeLayout
    $runtimeRequest = Join-Path $instance.Root 'webapps\Request\Web.config'
    if (Test-Path -LiteralPath $runtimeRequest) { Set-RequestWebConfig $runtimeRequest }
    Set-DDTank30WebRoot (Join-Path $instance.Root 'webroot')
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
    $pool = 'DDTank30Pool'
    foreach ($app in @(
        @{ Name='Request'; Path=(Join-Path $instance.Root 'webapps\Request') },
        @{ Name='gunny'; Path=(Join-Path $instance.Root 'webroot\gunny') },
        @{ Name='Register'; Path=(Join-Path $instance.Root 'webroot\Register') },
        @{ Name='admingunny'; Path=(Join-Path $instance.Root 'webroot\admingunny') }
    )) {
        if (-not (Test-Path -LiteralPath $app.Path)) { continue }
        $existing = Get-WebApplication -Site $site | Where-Object { $_.Path -ieq ('/' + $app.Name) }
        if ($existing) { Set-ItemProperty ("IIS:\Sites\$site\" + $app.Name) -Name applicationPool -Value $pool }
        else { New-WebApplication -Site $site -Name $app.Name -PhysicalPath $app.Path -ApplicationPool $pool | Out-Null }
    }
}

Write-Host "DDTANK30_INSTANCE_APPLY=PASS host=$($instance.PublicHost) web=$($instance.WebPort) game=$($instance.RoadPort) config=$($instance.ConfigPath)"