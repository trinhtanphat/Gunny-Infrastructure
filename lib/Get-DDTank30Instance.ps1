function Get-DDTank30Instance {
    [CmdletBinding()]
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        if ($env:GUNNY_INSTANCE_CONFIG) { $ConfigPath = $env:GUNNY_INSTANCE_CONFIG }
        elseif (Test-Path 'C:\Gunny-Infra\server-instance.json') { $ConfigPath = 'C:\Gunny-Infra\server-instance.json' }
        else { $ConfigPath = Join-Path $PSScriptRoot 'server-instance.example.json' }
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Gunny instance config not found: $ConfigPath" }
    $all = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $all.publicHost) { throw 'Instance config is missing publicHost.' }
    if (-not $all.ddtank30) { throw 'Instance config is missing ddtank30.' }
    $d = $all.ddtank30
    foreach ($name in @('root','webSite','webPort','roadPort','centerHost','centerPort','fightHost','fightPort','centerWcfHttpPort','centerWcfTcpPort')) {
        if ($null -eq $d.$name -or [string]::IsNullOrWhiteSpace([string]$d.$name)) { throw "ddtank30.$name is required." }
    }
    [pscustomobject]@{
        ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        PublicHost = [string]$all.publicHost
        Root = [string]$d.root
        WebSite = [string]$d.webSite
        WebPort = [int]$d.webPort
        RoadPort = [int]$d.roadPort
        CenterHost = [string]$d.centerHost
        CenterPort = [int]$d.centerPort
        FightHost = [string]$d.fightHost
        FightPort = [int]$d.fightPort
        CenterWcfHttpPort = [int]$d.centerWcfHttpPort
        CenterWcfTcpPort = [int]$d.centerWcfTcpPort
        DatabaseServerIds = @($d.databaseServerIds | ForEach-Object { [int]$_ })
    }
}