function Get-GunnyV389Instance {
    [CmdletBinding()]
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        if ($env:GUNNY_INSTANCE_CONFIG) { $ConfigPath=$env:GUNNY_INSTANCE_CONFIG }
        elseif (Test-Path 'C:\Gunny-Infra\server-instance.json') { $ConfigPath='C:\Gunny-Infra\server-instance.json' }
        else { $ConfigPath=Join-Path $PSScriptRoot 'server-instance.example.json' }
    }
    if(-not(Test-Path -LiteralPath $ConfigPath)){throw "Gunny instance config not found: $ConfigPath"}
    $all=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
    if(-not $all.publicHost){throw 'Instance config is missing publicHost.'}
    $internalHost=if($all.internalHost){[string]$all.internalHost}else{'127.0.0.1'}
    if($internalHost-ne'127.0.0.1'){throw 'internalHost must be 127.0.0.1 for single-host Gunny runtime.'}
    if(-not $all.legacyV389){throw 'Instance config is missing legacyV389.'}
    $v=$all.legacyV389
    foreach($name in @('root','webSite','webPort','roadPort','centerPort','fightPort','centerWcfHttpPort','centerWcfTcpPort')){
        if($null-eq$v.$name-or[string]::IsNullOrWhiteSpace([string]$v.$name)){throw "legacyV389.$name is required."}
    }
    [pscustomobject]@{
        ConfigPath=(Resolve-Path -LiteralPath $ConfigPath).Path
        PublicHost=[string]$all.publicHost
        InternalHost=$internalHost
        Root=[string]$v.root
        WebSite=[string]$v.webSite
        WebPort=[int]$v.webPort
        RoadPort=[int]$v.roadPort
        CenterPort=[int]$v.centerPort
        FightPort=[int]$v.fightPort
        CenterWcfHttpPort=[int]$v.centerWcfHttpPort
        CenterWcfTcpPort=[int]$v.centerWcfTcpPort
        DatabaseServerIds=@($v.databaseServerIds|ForEach-Object{[int]$_})
    }
}